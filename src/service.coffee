bb = require "bluebird"
msgpack = require('msgpack')
uuid = require 'node-uuid'
amqp = require("amqplib")
_ = require('lodash')


# Throwing the NAckError will cause the message to be put back on the queue.
# This is VERY DANGEROUS because if your service can never NAck the message
# it may live forever and cause all sorts of havoc

class NAckError extends Error
  constructor: () ->
    @name = "NAckError"
    @message = "NAck the Message"
    Error.captureStackTrace(this, NAckError)

class MessageNotDeliveredError extends Error
  constructor: (messageID, routingKey) ->
    @name = "MessageNotDeliveredError"
    @message = "message #{messageID} not delivered to #{routingKey}"
    Error.captureStackTrace(this, MessageNotDeliveredError)

generateUUID = ->
    uuid.v4().replace(/-/g,'')

class ServiceConnectionManager

  log : (message) ->
    console.log "#{(new Date()).toISOString()} - #{@uuid} - #{message}"

  constructor: (@ampq_uri, @uuid, @service_queue_name, @service_handler, @response_queue_name, @response_handler, @returned_handler) ->
    # The states are:
    #
    #                 restarting
    #                  A      |
    #                 error  start()
    #                  |      |
    #     starting ---> started --|
    #        A             |      |
    #      start()        stop()  |
    #        |             V      |
    #     stopped   <-  stopping  |
    #        |                    |
    #        |--------------------|
    #      kill()
    #        |
    #     killing
    #        |
    #        V
    #      dead

    @state = 'stopped'
    @in_flight_messages = {}

  get_connection: ->
    # can only get a connection if starting or started
    throw new Error("#{@uuid}: #get_connection rejected state #{@state}") if !@in_state(['started', 'starting'])

    return @_connection if @_connection
    #@log "creating connection"
    @_connection = amqp.connect(@ampq_uri)
    .then((connection) =>
      #@log "created connection"
      connection.on('error', (error) =>
        @log("AMQP Error connection error - #{error} - #{error.stack || ''}")
        @_connection = null
      )
      connection.on('close', =>
        @_connection = null #connection closed
      )
      connection
    )

  get_service_channel: ->
    #reject if not started, starting, or stopping to reply to messages
    throw new Error("#{@uuid}: #get_service_channel rejected state #{@state}") if !@in_state(['started','starting','stopping'])

    return @_service_channel if @_service_channel

    #@log "creating service channel"

    @_service_channel = @get_connection()
    .then( (connection) =>
      connection.createChannel()
    )
    .then( (service_channel) =>
      #@log "created service channel"
      # http://www.mariuszwojcik.com/2014/05/19/how-to-choose-prefetch-count-value-for-rabbitmq/
      # prefetch will grab a number of un ack'ed messages from the queue
      # since basically the first thing we do is ack a message this number can be quite low
      service_channel.prefetch 20

      service_channel.on('error', (error) =>
        @log "Service Channel Errored #{error}, #{error.stack}"
        @_service_channel = null
      )

      service_channel.on('return', (message) =>
        @log "Message Returned to Channel"
        @returned_handler(message)
      )

      service_channel.on('close', =>
        #@log "Service Channel Closed"
        @_service_channel = null
        if @state == 'started' # i.e. it should be currently running
          @log "AMQP Service Channel closed, restarting service"
          #then restart
          @restart()
        else
          @log "Service Channel stopped"
      )

      @create_response_queue(service_channel)
      .then( => @create_service_queue(service_channel))
      .then( -> service_channel) #return the service channel
    )

  create_response_queue: (service_channel) ->
    if @response_queue_name
      #@log "Creating response queue"
      fn = (msg) =>
        #@log "recieved response message ID `#{JSON.stringify(msg.properties)}`"

        # response immediately acks because no other service is listening to it
        service_channel.ack(msg)
        @response_handler(msg)


      service_channel.assertQueue(@response_queue_name, {expires: 1000})
      .then( (response_queue) =>
        service_channel.consume(@response_queue_name, fn)
      )
    else
      bb.try( -> )

  create_service_queue: (service_channel) ->
    if @service_queue_name
      #@log "Creating service queue"
      fn = (msg) =>
        # @log "recieved service message ID `#{msg.properties.messageId}`"
        #
        # Conditions
        # 1. The Service Function Succeeds
        # 2. The Service Function Has an Unknown Error
        # 3. The Service has a NAckError Error
        # 4. The Service is killed or dies while processing the message

        # 1. will ack the message
        # 2. will log the error then ack the message
        # 3. will log the error then nack the message (so that another service can handle it later)
        # 4. will cause the service channel to die which will not ack the message
        #


        # console.log 'add message', _.keys(@in_flight_messages).length
        @in_flight_messages[msg.properties.messageId] = bb.try( => @service_handler(msg))
        .then( ->
          service_channel.ack(msg)
        )
        .catch( NAckError, (err) ->
          console.error "NACKed MESSAGE", err.stack
          service_channel.nack(msg)
        )
        .catch( (err) ->
          # If the service has not handled this error, then remove it
          console.error "Service Channel Error", err.stack
          service_channel.ack(msg)
        )
        .finally( =>
          delete @in_flight_messages[msg.properties.messageId]
          #console.log 'remove message', _.keys(@in_flight_messages).length
        )

      service_channel.assertQueue(@service_queue_name, {durable: true})
      .then( =>
        service_channel.consume(@service_queue_name, fn)
      )
      .then( (ret) =>
        @_service_queue_consumer_tag = ret.consumerTag
      )
    else
      bb.try( -> )

  restart: ->
    throw new Error("#{@uuid}: #restart rejected state #{@state}") if !@in_state(['started'])
    @change_state('restarting')
    @start()

  start: ->
    return bb.try( -> true) if @state == 'started'
    # can only start from stopped or restarting
    throw new Error("#{@uuid}: #start rejected state #{@state}") if  !@in_state(['stopped', 'restarting'])
    @change_state('starting')
    try
      @get_service_channel()
      .then( =>
        @change_state('started')
      )
    catch error
      bb.try( -> throw error) # turn actual error into promise error

  stop: ->
    return bb.try( -> true) if @state == 'stopped'
    throw new Error("#{@uuid}: #stop rejected state #{@state}") if !@in_state(['started'])
    bb.all([@get_service_channel(), @get_connection()])
    .spread( (channel, connection) =>
      @change_state('stopping')
      #stop receiving calls
      if @_service_queue_consumer_tag
        stop = channel.cancel(@_service_queue_consumer_tag)
      else
        stop = bb.try(->)

      stop.then( =>
        bb.all(_.values(@in_flight_messages))
      )
      .then( ->
        connection.close()
      )
    )
    .then( =>
      @change_state('stopped')
    )

  in_state: (states) ->
    for s in states
      if @state == s
        return true

    return false

  change_state: (state) ->
    @log "#{@state} -> #{state}"
    @state = state

  kill: ->
    throw new Error("#{@uuid}: #kill rejected state #{@state}") if !@in_state(['stopped','started'])
    @get_connection()
    .then( (connection) =>
      @change_state('killing')
      connection.close()
    )
    .then( =>
      @change_state('dead')
    )

  sendMessage: (exchange, routing_key, payload, options) ->
    @get_service_channel()
    .then( (service_channel) =>
      service_channel.publish(exchange, routing_key, payload, options)
    )


class Service
  @TimeoutError = bb.TimeoutError
  @MessageNotDeliveredError = MessageNotDeliveredError
  @NAckError = NAckError
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

    @connection_manager = new ServiceConnectionManager(
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

    deferred.resolve_promise(msgpack.unpack(msg.content))

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
