bb = require "bluebird"
msgpack = require('msgpack')
Util = require("./util")
ServiceConnectionManger = require('./service_connection_manager')
_ = require('lodash')

class Service
  @TimeoutError = bb.TimeoutError

  constructor: (@name, options = {}) ->
    @options = _.defaults(
      options,
      {
        service_queue: true
        responce_queue: true
        ampq_uri: 'amqp://localhost'
        timeout: 1000
        service_fn:
          (payload) -> {}
      }
    )
    throw "Service Name undefined" if !@name
    @uuid = "#{@name}.#{Util.generateUUID()}"
    @transactions = {}

    if @options.responce_queue
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
    @connection_manager.stop()

  # Send a message internally
  sendMessageToService: (service, payload) ->
    @sendMessageToServiceOrResource(service, payload)

  sendMessageToResource: (payload) ->
    if not payload.path
      throw "payload must contain path"

    @sendMessageToServiceOrResource(null, payload)

  sendMessageToServiceOrResource: (service, payload) ->

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
      body:        payload.body        || {}
      log:         payload.log         || {}
    }
    
    # If an x-interaction-id header is present in the payload's
    # headers we use it, otherwise generate one. The presence of an interaction
    # id indicates that this message originated internally since all external
    # http requests have anything that looks like an interaction id stripped
    # out of them in EdgeSplitter's onHTTPRequest function.
    if !http_payload.headers['x-interaction-id']
      http_payload.headers['x-interaction-id'] = Util.generateUUID()

    

    messageId = Util.generateUUID()
    http_message_options =
      messageId: messageId
      type: 'http_request'
      replyTo: @response_queue_name
      contentEncoding: '8bit'
      contentType: 'application/octet-stream'

    #create the deferred
    deferred = bb.defer()
    @transactions[messageId] = deferred
    returned_promise = deferred.promise

    
    returned_promise.timeout(@options.timeout)
    .catch(bb.TimeoutError, (err) =>
      return if deferred.promise.isFulfilled() #Under stress the error can be thrown when already resolved
      console.warn "#{@uuid}: Timeout for message ID `#{messageId}`"
      deferred.reject(err)
    )

    #handle the response
    returned_promise.finally( =>
      delete @transactions[messageId]
    )

    if service
      message_promise = @sendRawMessageToService(service, http_payload, http_message_options)
      .then( =>
        returned_promise
      )
    else 
      resource_topic = Util.pathToTopic(http_payload.path)
      message_promise = @sendRawMessageToResource(resource_topic, http_payload, http_message_options)
      .then( =>
        returned_promise
      )
    
    
    message_promise.messageId = messageId
    message_promise.transactionId = http_payload.headers['x-interaction-id']
    message_promise.response_queue_name = @response_queue_name
    
    #Send the message on the queue
    message_promise

  processMessageReturned: (msg) =>
    deferred = @transactions[msg.properties.messageId]
    return if not deferred
    return deferred.reject("message returned")

  processMessageResponse: (msg) =>
    deferred = @transactions[msg.properties.correlationId]

    if not deferred? or msg.properties.type != 'http_response'
      console.warn "#{@uuid}: Received Unsolicited Response message ID `#{msg.properties.messageId}`, correlationId: `#{msg.properties.correlationId}` type '#{msg.properties.type}'"
      deferred.reject("Property type wrong") if deferred
      return

    deferred.resolve([msg, msgpack.unpack(msg.content)])

  receiveMessage: (msg) =>
    type = msg.properties.type

    if type == 'metering_event'
      return @receiveUtilityEvent(msg)
    else if type == 'hoodoo_service_middleware_amqp_log_message'
      return @receiveUtilityEvent(msg)
    else if type == 'logging_event'
      return @receiveUtilityEvent(msg)
    else if type == 'http_request'
      return @receiveHTTPRequest(msg)
    else
      console.warn "#{@uuid}: Received message with unsupported type #{type}"


  receiveUtilityEvent: (msg) ->
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
    service_to_reply_to = msg.properties.replyTo
    message_replying_to = msg.properties.messageId
    this_message_id = Util.generateUUID()

    if not (service_to_reply_to and message_replying_to)
      console.warn "#{@uuid}: Received message with no ID and/or Reply type'"

    #process the message
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
      
      resp = {}
      resp.body = response.body || {}
      resp.status_code =  response.status_code || 200
      resp.headers = response.headers || { 'x-interaction-id': payload.headers['x-interaction-id']}


      @replyToServiceMessage(
        service_to_reply_to,
        resp,
        { 
          type: 'http_response', 
          correlationId: message_replying_to,
          messageId: this_message_id
        }
      )
        
    ).catch( (err) ->
      console.log "SEND MESSAGE ERROR"
      console.log err.stack
      throw err
    )



  addResourceToService: (resource) ->
    @connection_manager.addResourceToService(resource)

  replyToServiceMessage: (service, payload, options) ->
    @sendRawMessageToService(service, payload, options)

  sendRawMessageToService: (service, payload, options) ->
    @connection_manager.sendMessageToService(service, msgpack.pack(payload), options)

  sendRawMessageToResource: (resource, payload, options) ->
    console.log "Sending message to resource"
    @connection_manager.sendMessageToResource(resource, msgpack.pack(payload), options)


module.exports = Service
