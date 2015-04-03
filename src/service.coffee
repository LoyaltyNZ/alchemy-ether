bb = require "bluebird"
amqp = bb.promisifyAll(require("amqplib/callback_api"))
msgpack = require('msgpack')
Util = require("./util")

_ = require('underscore')

class Service
  @TimeoutError = bb.TimeoutError

  constructor: (@name, options = {}) ->
    @options = _.defaults(
      options,
      {
        service_queue: true
        ampq_uri: 'amqp://localhost'
        timeout: 1000
        service_fn:
          (payload) -> {}
      }
    )
    throw "Service Name undefined" if !@name
    @uuid = "#{@name}.#{Util.generateUUID()}"
    @transactions = {}
    @response_queue_name = @uuid
    @service_queue_name = @name

  start: ->
    #console.info "Starting #{@uuid} service"
    connect_promise = amqp.connectAsync(@options.ampq_uri)
    .catch( ->
      throw "Error connecting to RabbitMQ"
    )

    connect_promise
    .then((connection) =>
      @connection = bb.promisifyAll(connection)
      @connection.createChannelAsync()
    )
    .then( (serviceChannel) =>
      @serviceChannel = bb.promisifyAll(serviceChannel)
      @serviceChannel.prefetch 256
      @serviceChannel.assertQueueAsync(@response_queue_name, {exclusive:true, autoDelete:true})
    )
    .then( (response_queue) =>
      @response_queue = bb.promisifyAll(response_queue)
      @serviceChannel.consume(@response_queue_name, @processMessageResponse)
    )
    .then( =>
      if @options.service_queue
        @serviceChannel.assertQueueAsync(@service_queue_name, {durable: false}) 
      else
        false
    )
    .then( (service_queue) =>
      if @options.service_queue
        @service_queue = bb.promisifyAll(service_queue)
        @serviceChannel.consume(@service_queue_name, @receiveMessage)
      else
        false
    )
    .then( =>
      #console.log "Started #{@uuid} service"
      @
    )

  stop: ->
    #console.log "Stopping #{@uuid} service"
    @connection.closeAsync()
    .then( =>
      #console.log "Stopped #{@uuid} service"
    )

  # Send a message internally
  sendMessage: (service, payload) ->

    # Add in headers if there are none
    if !payload.headers
      payload.headers = {}

    # If an x-interaction-id header is present in the payload's
    # headers we use it, otherwise generate one. The presence of an interaction
    # id indicates that this message originated internally since all external
    # http requests have anything that looks like an interaction id stripped
    # out of them in EdgeSplitter's onHTTPRequest function.
    if !payload.headers['x-interaction-id']
      payload.headers['x-interaction-id'] = Util.generateUUID()

    messageId = Util.generateUUID()
    options =
      messageId: messageId
      type: 'http_request'
      replyTo: @response_queue_name
      contentEncoding: '8bit'
      contentType: 'application/octet-stream'


    deferred = bb.defer()
    @transactions[messageId] = deferred

    @sendRawMessage(service, payload, options)
    .timeout(@options.timeout)
    .catch(bb.TimeoutError, (err) =>
      return if deferred.promise.isFulfilled() #Under stress the error can be thrown when already resolved
      console.warn "#{@uuid}: Timeout for message ID `#{messageId}`"
      deferred.reject(err)
    )

    message_promise = deferred.promise
    #handle the response
    message_promise.finally( =>
      delete @transactions[messageId]
    )

    message_promise


    message_promise.service = service
    message_promise.messageId = messageId
    message_promise.transactionId = payload.headers['x-interaction-id']
    message_promise.response_queue_name = @response_queue_name
    message_promise

  processMessageResponse: (msg) =>
    @_acknowledge(msg)
    deferred = @transactions[msg.properties.correlationId]

    if not deferred? or msg.properties.type != 'http_response'
      console.warn "#{@uuid}: Received Unsolicited Response message ID `#{msg.properties.messageId}`, correlationId: `#{msg.properties.correlationId}` type '#{msg.properties.type}'"
      deferred.reject("Property type wrong") if deferred
      return

    deferred.resolve([msg, msgpack.unpack(msg.content)])

  receiveMessage: (msg) =>
    @_acknowledge(msg)

    type = msg.properties.type
    
    if type == 'metering_event'
      return @receiveMeteringEvent(msg)
    else if type == 'http_request'
      return @receiveHTTPRequest(msg)
    else
      console.warn "#{@uuid}: Received message with unsupported type #{type}"


  receiveMeteringEvent: (msg) ->
    if msg.content
      payload = msgpack.unpack(msg.content) 
    else
      payload = {}
    bb.try( => @options.service_fn(payload))

  receiveHTTPRequest: (msg) ->
    if msg.content
      payload = msgpack.unpack(msg.content) 
    else
      payload = {body: {}, headers: {}}

    #responce info
    queue_to_reply_to = msg.properties.replyTo
    message_replying_to = msg.properties.messageId
    this_message_id = Util.generateUUID()

    if not (queue_to_reply_to and message_replying_to)
      console.warn "#{@uuid}: Received message with no ID and/or Reply type'"

    #process the message
    # TODO log incoming call
    bb.try( => @options.service_fn(payload))
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

      response = _.defaults(response, {
        body: {}
        status_code: 200
        headers: {
          'x-interaction-id': payload.headers['x-interaction-id']
        }
      })

      @sendRawMessage(
        queue_to_reply_to,
        response, 
        { 
          type: 'http_response', 
          correlationId: message_replying_to,
          messageId: this_message_id
        }
      )
        
    ).catch( (err) ->
      console.log err
    )

  sendRawMessage: (queue, payload, options) ->
    @serviceChannel.publishAsync('', queue, msgpack.pack(payload), options)

  _acknowledge: (message) =>
    @serviceChannel.ack(message)      

module.exports = Service
