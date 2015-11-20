bb = require "bluebird"
msgpack = require('msgpack')
uuid = require 'node-uuid'

ServiceConnectionManger = require('./service_connection_manager')
_ = require('lodash')

class MessageNotDeliveredError extends Error
  constructor: (messageID, routingKey) ->
    @name = "MessageNotDeliveredError"
    @message = "message #{messageID} not delivered to #{routingKey}"
    Error.captureStackTrace(this, MessageNotDeliveredError)

generateUUID = ->
    uuid.v4().replace(/-/g,'')

class Service
  @TimeoutError = bb.TimeoutError
  @MessageNotDeliveredError = MessageNotDeliveredError
  @NAckError = ServiceConnectionManger.NAckError
  @generateUUID = generateUUID


  constructor: (@name, options = {}) ->
    @options = _.defaults(
      options,
      {
        service_queue: true
        response_queue: true
        ampq_uri: 'amqp://localhost'
        timeout: 1000
        service_fn:
          (payload) -> {}
      }
    )
    throw "Service Name undefined" if !@name
    @uuid = "#{@name}.#{generateUUID()}"
    @transactions = {}

    if @options.response_queue
      @response_queue_name = @uuid
    else
      @response_queue_name = null

    if @options.service_queue
      @service_queue_name = @name
    else
      @service_queue_name = null

    @connection_manager = new ServiceConnectionManger(
      @options.ampq_uri,
      @uuid,
      @service_queue_name,
      @receiveMessage,
      @response_queue_name,
      @processMessageResponse,
      @processMessageReturned
    )

  start: ->
    @connection_manager.start()


  stop: ->
    transaction_promises = _.values(@transactions).map( (tx) ->
      tx.promise.catch( (e) ->
        console.log e
      )
    )

    if transaction_promises.length > 0
      bb.any(transaction_promises)
      .catch( (e) ->
        console.log e
      )
      .finally( =>
        @connection_manager.stop()
      )
    else
      @connection_manager.stop()

  kill: ->
    @connection_manager.kill()

  # Send a message internally
  sendMessageToService: (service, payload) ->
    @sendHttpRequestMessage('', service, payload)

  sendHttpRequestMessage: (exchange, service, payload) ->

    # Set Up Default
    http_payload = {
      session_id:  payload.session_id
      scheme:      payload.protocol    || 'http'
      host:        payload.hostname    || 'localhost'
      port:        payload.port        || 8080
      path:        payload.path        || "/"
      query:       payload.query       || {}
      verb:        payload.verb        || "GET"
      headers:     payload.headers     || {}
      body:        payload.body        || ""
      log:         payload.log         || {}
    }

    # If an x-interaction-id header is present in the payload's
    # headers we use it, otherwise generate one. The presence of an interaction
    # id indicates that this message originated internally since all external
    # http requests will be stripped
    if !http_payload.headers['x-interaction-id']
      http_payload.headers['x-interaction-id'] = generateUUID()


    messageId = generateUUID()
    http_message_options =
      messageId: messageId
      type: 'http_request'
      replyTo: @response_queue_name
      contentEncoding: '8bit'
      contentType: 'application/octet-stream'
      expiration: @options.timeout

    #create the returned_promise
    deferred = {}
    returned_promise = new bb( (resolve, reject) ->
      deferred.resolve_promise = resolve
      deferred.reject_promise = reject
    )
    deferred.promise = returned_promise

    @transactions[messageId] = deferred

    returned_promise = returned_promise.timeout(@options.timeout)

    returned_promise.timeout(@options.timeout)
    .catch(bb.TimeoutError, (err) =>
      return if returned_promise.isFulfilled() #Under stress the error can be thrown when already resolved
      console.warn "#{@uuid}: Timeout for message ID `#{messageId}`"
      throw err
    )
    .catch(Service.MessageNotDeliveredError, (err) =>
      console.warn "#{@uuid}: MessageNotDeliveredError for message ID `#{messageId}`"
      throw err
    )
    .finally( =>
      delete @transactions[messageId]
    )

    #seperate out
    message_promise = @sendMessage(exchange, service, http_payload, http_message_options)
    .then( =>
      returned_promise
    )

    message_promise.messageId = messageId
    message_promise.transactionId = http_payload.headers['x-interaction-id']
    message_promise.response_queue_name = @response_queue_name

    #Send the message on the queue
    message_promise

  processMessageReturned: (msg) =>
    deferred = @transactions[msg?.properties?.messageId]
    return if not deferred
    return deferred.reject_promise(new Service.MessageNotDeliveredError(msg?.properties?.messageId, msg?.fields?.routingKey))

  processMessageResponse: (msg) =>
    deferred = @transactions[msg.properties.correlationId]
    if not deferred? or msg.properties.type != 'http_response'
      console.warn "#{@uuid}: Received Unsolicited Response message ID `#{msg.properties.messageId}`,
      correlationId: `#{msg.properties.correlationId}`
      type '#{msg.properties.type}'"
      deferred.reject_promise("Property type wrong") if deferred
      return

    deferred.resolve_promise([msg, msgpack.unpack(msg.content)])

  receiveMessage: (msg) =>
    type = msg.properties.type
    if type == 'http_request'
      return @receiveHTTPRequest(msg)
    else
      @receiveUtilityEvent(msg)

  receiveUtilityEvent: (msg) ->
    type = msg.properties.type

    if msg.content
      payload = msgpack.unpack(msg.content)
    else
      payload = {}

    bb.try( =>
      @options.service_fn(payload)
    ).catch( (err) =>
      console.error "#{@uuid} UTILITY_ERROR from message type #{type}", err.stack
      throw err #Propagate up the stack
    )

  receiveHTTPRequest: (msg) ->
    if msg.content
      payload = msgpack.unpack(msg.content)
    else
      payload = {body: {}, headers: {}}

    #response info
    service_to_reply_to = msg.properties.replyTo
    message_replying_to = msg.properties.messageId
    this_message_id = generateUUID()

    if not (service_to_reply_to and message_replying_to)
      console.warn "#{@uuid}: Received message with no ID and/or Reply type'"

    # process the message
    # TODO log incoming call
    bb.try( =>
      @options.service_fn(payload)
    )
    .then( (response = {}) =>
      #service function must return a response object with
      # {
      #   body:
      #   status_code:
      #   headers: {}
      # }
      #1. JSON body
      #2. RESPONSE Object
      #3.
      #reply if the information is there

      resp = {
        status_code:  response.status_code || 200
        headers: response.headers || { 'x-interaction-id': payload.headers['x-interaction-id']}
        body: response.body || {}
      }

      @replyToServiceMessage(
        service_to_reply_to,
        resp,
        {
          type: 'http_response',
          correlationId: message_replying_to,
          messageId: this_message_id
        }
      )
    ).catch( (err) =>
      console.error "#{@uuid} HTTP_ERROR", err.stack
      resp = {
        status_code: 500
        headers: {
          'x-interaction-id': payload.headers['x-interaction-id']
        }
        body: {
          code: 'service.fault'
          message: 'An unexpected error occurred'
        }
      }

      # If all else fails
      @replyToServiceMessage(
        service_to_reply_to,
        resp,
        {
          type: 'http_response',
          correlationId: message_replying_to,
          messageId: this_message_id
        }
      )

      throw err # reraise the error to the service channel layer
    )

  replyToServiceMessage: (response_queue, payload, options) ->
    #directly respond to message
    @sendMessage('', response_queue, payload, options)

  sendMessage: (exchange, service, payload, options) ->
    options.mandatory = true if options.type == 'http_request'
    @connection_manager.sendMessage(exchange, service, msgpack.pack(payload), options)


module.exports = Service
