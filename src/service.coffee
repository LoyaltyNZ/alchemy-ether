bb = require "bluebird"
msgpack = require('msgpack')
Util = require("./util")
ServiceConnectionManger = require('./service_connection_manager')
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

    if @options.service_queue
      @service_queue_name = @name
    else
      @service_queue_name = null

    @connection_manager = new ServiceConnectionManger(@options.ampq_uri, @service_queue_name, @receiveMessage, @response_queue_name, @processMessageResponse)

  start: ->
    try
      @connection_manager.start()
    catch error
      bb.try( -> throw error)

  stop: ->
    @connection_manager.stop()

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


    message_promise = @sendRawMessage(service, payload, options)
    .then( =>
      returned_promise
    )

    message_promise.service = service
    message_promise.messageId = messageId
    message_promise.transactionId = payload.headers['x-interaction-id']
    message_promise.response_queue_name = @response_queue_name
    

    #Send the message on the queue
    
    message_promise

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
      console.log "SEND MESSAGE ERROR"
      console.log err.stack
      throw err
    )

  sendRawMessage: (queue, payload, options) ->
    @connection_manager.sendMessage(queue, msgpack.pack(payload), options)
   

module.exports = Service
