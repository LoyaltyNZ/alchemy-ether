# # Alchemy Service
#
# The main class of Alchemy-Ether is `Service`.
# This implements all the functions necessary for sending, receiving and processing messages.
# It uses a `ServiceConnectionManager` which is state driven to manage the connection between the service and RabbitMQ.

# ## Imports
#
# * `bluebird` is the promises library
# * `msgpack` is used to compress the sent messages
# * `uuid` is used to generate unique IDs
# * `amqp` is used to connect to RabbitMQ
# * `lodash` is used as a general purpose utility library
bb = require "bluebird"
msgpack = require('msgpack')
uuid = require 'node-uuid'
amqp = require("amqplib")
_ = require('lodash')


#
# ## Service
#

# The service class is the primary class used when creating an Alchemy Service
#
class Service

  #
  # [Version 4](https://en.wikipedia.org/wiki/Universally_unique_identifier#Version_4_.28random.29) UUIDS are used for identifiers in the Alchemy framework.
  # These are generated by the [node-uuid](https://www.npmjs.com/package/node-uuid) package, and the `-`'s removed
  @generateUUID: -> uuid.v4().replace(/-/g,'')

  # A `Service` is constructed with a required `name` (e.g. `B`) a map of options:
  # * `amqp_uri`: URI to RabbitMQ (default `'amqp://localhost'`)
  # * `service_queue`: create a service queue (default `true`)
  # * `response_queue`: create a response queue (default `true`)
  # * `timeout`: the timeout in ms to wait for responses from other services (default `1000`)
  #
  # and a service_fn
  # * `service_fn`: the function the service uses to process messages (default `-> {}`)
  #
  # the `service_fn` should respond with an object that looks like:
  # {
  #   body: {}
  #   status_code: 200
  #   headers: {}
  # }
  # This will then be sent back to the calling service.
  #
  # The UUID of the Service is the name plus a generated UUID, this is the service instance name
  #
  # `transactions` keeps track of outgoing messages, so the service can match up sent messages to responses
  # and nicely stop the service by waiting for outgoing transactions to finish
  #
  # Also, constructing the Service creates a `ServiceConnectionManager` to manage the RabbitMQ connection
  constructor: (@name, options = {}, @service_fn = ( (msg) -> {})) ->
    @options = _.defaults(
      options,
      {
        amqp_uri: 'amqp://localhost'
        service_queue: true
        response_queue: true
        timeout: 1000,
        resource_paths: []
      }
    )

    throw "Service Name undefined" if !@name
    @uuid = "#{@name}.#{Service.generateUUID()}"
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
      @options.amqp_uri,
      @service_queue_name,
      @process_service_queue_message,
      @response_queue_name,
      @process_response_queue_message,
      @process_returned_message
    )

  #
  # #### Life Cycle
  #

  # `start` starts the Service
  start: ->
    @connection_manager.start()

  # `stop` stops the service nicely by waiting for responses to outgoing messages or for them to timeout
  stop: ->
    transaction_promises = _.values(@transactions).map( (tx) ->
      tx.promise.catch( (e) =>
        _log_error @uuid, "Stopping Transaction Error", e
      )
    )

    if transaction_promises.length > 0
      bb.any(transaction_promises)
      .catch( (e) =>
        _log_error @uuid, "Stopping Transaction Error", e
      )
      .finally( =>
        @connection_manager.stop()
      )
    else
      @connection_manager.stop()

  # `kill` will kill the service immediately
  kill: ->
    @connection_manager.kill()

  #
  # #### Sending Messages
  #

  # `send_message` sends a message to an exchange and queue
  send_message: (exchange, queue, message, options) ->
    @connection_manager.publish_message(exchange, queue, msgpack.pack(message), options)

  # `send_message_to_service` send a `message` to a service with `service_name`
  send_message_to_service: (service_name, message) ->
    @send_HTTP_request_message('', service_name, message)

  # `send_HTTP_request_message` sends a http(ish) message to an exchange and queue
  #
  # The message is formatted in using HTTP concepts like headers, path, and body
  #
  # The `x-interaction-id` header is used to identify a single external interaction that may involve calls to multiple services.
  # By following the `x-interaction-id` around the system the involved services in a single interaction can be identified
  # If an x-interaction-id header is present in the message's headers we use it,
  # otherwise we generate one.
  #
  # The `http_message_options` sent with the message is the:
  # 1. `messageID` to identify the message
  # 2. `type` of `http_request` so the opposing service knows how to handle it
  # 3. `replyTo` the queue to publish the response message
  # 4. `contentEncoding` and `contentType` for encoding
  # 5. `expiration` so the message expires if the service is overloaded
  # 6. `mandatory` so the message is returned if it cannot be routed to a service
  #
  # The `response_deferred` deferred object promises that this message will be responded to within a time limit
  #
  # The `request_promise` is the promise that the message is sent then responded to.
  # Additional information that may be useful to the service is then returned
  send_HTTP_request_message: (exchange, queue, message) ->
    http_message = {
      session_id:  message.session_id
      scheme:      message.protocol    || 'http'
      host:        message.hostname    || 'localhost'
      port:        message.port        || 8080
      path:        message.path        || "/"
      query:       message.query       || {}
      verb:        message.verb        || "GET"
      headers:     message.headers     || {}
      body:        message.body        || ""
    }

    if !http_message.headers['x-interaction-id']
      http_message.headers['x-interaction-id'] = Service.generateUUID()

    messageId = Service.generateUUID()


    http_message_options =
      messageId: messageId
      type: 'http_request'
      replyTo: @response_queue_name
      contentEncoding: '8bit'
      contentType: 'application/octet-stream'
      expiration: @options.timeout
      mandatory: true

    response_deferred = {}
    @transactions[messageId] = response_deferred

    response_deferred.promise = new bb( (resolve, reject) ->
      response_deferred.resolve_promise = resolve
      response_deferred.reject_promise = reject
    )
    .timeout(@options.timeout)
    .catch(Service.TimeoutError, (err) =>
      return if response_deferred.promise.isFulfilled()
      _log_error @uuid, "Timeout for message ID `#{messageId}`"
      throw err
    )
    .catch(Service.MessageNotDeliveredError, (err) =>
      _log_error @uuid, "MessageNotDeliveredError for message ID `#{messageId}`"
      throw err
    )
    .finally( =>
      delete @transactions[messageId]
    )

    request_promise = @send_message(exchange, queue, http_message, http_message_options)
    .then( =>
      response_deferred.promise
    )

    request_promise.messageId = messageId
    request_promise.transactionId = http_message.headers['x-interaction-id']
    request_promise.response_queue_name = @response_queue_name

    request_promise

  # `process_response_queue_message` processes response messages from other the response queue
  #
  # First it checks to see if it is a waiting transaction.
  # If there is no matched transactions or the message type is incorrect
  # it logs an error and/or rejects the transaction
  #
  # If there is a transaction or the right type it will resolve the promise with the unpacked message.
  process_response_queue_message: (msg) =>
    deferred = @transactions[msg.properties.correlationId]
    if not deferred? or msg.properties.type != 'http_response'
      _log_message_error(@uuid, "Received Unsolicited Message on Response Queue", msg)
      deferred.reject_promise("Property type wrong") if deferred
      return
    deferred.resolve_promise(msgpack.unpack(msg.content))

  # `process_returned_message` processes returned messages
  #
  # First it checks to see if it is a waiting transaction
  # If there is no matched transactions it logs and returns
  # If a matched transaction is fond it rejects with a MessageNotDeliveredError
  process_returned_message: (msg) =>
    deferred = @transactions[msg?.properties?.messageId]
    if not deferred
      _log_message_error(@uuid, "Received Unsolicited Message on Return Queue", msg)
      return
    return deferred.reject_promise(new Service.MessageNotDeliveredError(msg?.properties?.messageId, msg?.fields?.routingKey))

  #
  # #### Receiving and Responding To Messages
  #

  # `process_service_queue_message` processes messages received on the service queue
  #
  # If the message is type of `http_request` then pass to `receive_HTTP_request` as it expects a response,
  # otherwise pass to `receive_utility_event`.
  process_service_queue_message: (msg) =>
    type = msg.properties.type
    if type == 'http_request'
      return @receive_HTTP_request(msg)
    else
      @receive_utility_event(msg)

  # `receive_utility_event` receives messages of types where no response is necessary
  receive_utility_event: (msg) ->
    type = msg.properties.type

    if msg.content
      message = msgpack.unpack(msg.content)
    else
      message = {}

    bb.try( =>
      @service_fn(message)
    ).catch( (err) =>
      _log_error(@uuid, "UTILITY_ERROR from message type #{type}", err)
      throw err
    )

  # `receive_HTTP_request` is the message that receives the messages of type `http_request`
  #  and passes them to the `service_fn` to process and respond
  #
  # First it unpacks and extracts the message properties.
  # Then it calls the `service_fn`, gets the result and packages it up into
  # HTTPish object and replies to the messaging service.
  # If the `service_fn` throw an error the error is logged and an
  # HTTPish error object with status_code 500 is sent to the messaging service.
  receive_HTTP_request: (msg) ->
    if msg.content
      message = msgpack.unpack(msg.content)
    else
      message = {body: {}, headers: {}}

    service_to_reply_to = msg.properties.replyTo
    message_replying_to = msg.properties.messageId
    this_message_id = Service.generateUUID()

    bb.try( =>
      @service_fn(message)
    )
    .then( (response = {}) =>
      resp = {
        status_code:  response.status_code || 200
        headers: response.headers || { 'x-interaction-id': message.headers['x-interaction-id']}
        body: response.body || {}
      }

      @_reply_to_service_message(
        service_to_reply_to,
        resp,
        {
          type: 'http_response',
          correlationId: message_replying_to,
          messageId: this_message_id
        }
      )
    ).catch( (err) =>
      _log_error(@uuid, "service_fn HTTP_ERROR", err)
      resp = {
        status_code: 500
        headers: {
          'x-interaction-id': message.headers['x-interaction-id']
        }
        body: {
          code: 'service.fault'
          message: 'An unexpected error occurred'
        }
      }

      @_reply_to_service_message(
        service_to_reply_to,
        resp,
        {
          type: 'http_response',
          correlationId: message_replying_to,
          messageId: this_message_id
        }
      )
      throw err
    )

  # `_reply_to_service_message` responds to a service on its response queue
  _reply_to_service_message: (response_queue, message, options) ->
    @send_message('', response_queue, message, options)


# ## Service Connection Manager
#
# The `ServiceConnectionManager` maintains the connection to RabbitMQ and handles errors and the integration with the service.
# It is **state based** i.e. it has a `state` that can be altered via functions and events through known paths,
# and the functions can be valid only in certain states.
#
# Its state diagram is:
# ```
#                  restarting
#                   A      |
#                  error  start()
#                   |      |
#      starting ---> started --|
#         A             |      |
#       start()        stop()  |
#         |             V      |
#      stopped*  <-  stopping  |
#         |                    |
#         |--------------------|
#       kill()
#         |
#         |
#         V
#       killing
#         |
#         V
#        dead
# ```
#
# The states are `stopped`, `starting`, `started`, `stopping`, `restarting`, `killing` and `dead`.
# The initial state is `stopped`, the function `start()` will move it to the state `starting` then `started`.
#
# From the `started` state:
# 1. an `error` can occur, causing the state becomes `restarting` then back to `started`
# 2. `stop()` can be called to move it to `stopping` then `stopped`
# 3. `kill()` can be called to move it `killing` then `dead`
#
class ServiceConnectionManager


  # `constructor(amqp_uri, service_queue_name, service_handler, response_queue_name, response_handler, returned_handler)`
  # 1. `amqp_uri`           : the string URI to amqp
  # 2. `service_queue_name` : the string name of the service
  # 3. `service_handler`    : the function to process a message
  # 4. `response_queue_name`: the string response queue name
  # 5. `response_handler`   : the function to handle responses
  # 6. `returned_handler`   : the function to handle returned messages
  #
  # This sets the initial state to `stopped`
  #
  # `processing_messages` is used to store the `message_id` to the promise of the currently processing message.
  # So if a `stop` is called we can wait for currently processing messages.
  constructor: (@amqp_uri, @service_queue_name, @service_handler, @response_queue_name, @response_handler, @returned_handler) ->
    @state = 'stopped'
    @processing_messages = {}

  #
  # #### Life Cycle
  #

  # `start` is used to initialize the connections, channels and queues to RabbitMQ
  #
  # This function will raise exception if state is not `started`, `stopped` or `restarting`
  start: ->
    @_assert_state(['started', 'stopped', 'restarting'])
    return bb.try( -> true) if @state == 'started'
    @_change_state('starting')
    try
      @get_service_channel()
      .then( =>
        @_change_state('started')
      )
    catch error
      bb.try( -> throw error)

  # `stop` will attempt to nicely stop the service waiting for messages to stop processing
  #
  # This function will raise exception if state is not `started` or `stopped`
  #
  # While stopping the service will stop consuming the service queue
  # to stop processing new messages
  #
  # Then it will wait for all currently processing messages to finish
  # before closing the connection and changing the state
  stop: ->
    @_assert_state(['stopped', 'started'])
    return bb.try( -> true) if @state == 'stopped'

    bb.all([@get_service_channel(), @get_connection()])
    .spread( (channel, connection) =>
      @_change_state('stopping')

      if @_service_queue_consumer_tag
        stop_processing = channel.cancel(@_service_queue_consumer_tag)
      else
        stop_processing = bb.try(->)

      stop_processing.then( =>
        bb.all(_.values(@processing_messages))
      )
      .then( ->
        connection.close()
      )
    )
    .then( =>
      @_change_state('stopped')
    )

  # `restart` will try restart the connection and channel if an error occurs
  #
  # This function will raise exception if state is not `started`
  restart: ->
    @_assert_state(['started'])
    @_change_state('restarting')
    @start()

  # `kill` will immediately stop the service processing (use stop for nice shutdown)
  #
  # This function will raise exception if state is not `started` or `stopped`
  kill: ->
    @_assert_state(['stopped','started'])

    @get_connection()
    .then( (connection) =>
      @_change_state('killing')
      connection.close()
    )
    .then( =>
      @_change_state('dead')
    )

  # `_assert_state` will raise an exception if the current state is not in `states`
  _assert_state: (states) ->
    for s in states
      if @state == s
        return true
    return throw new Error("#{@response_queue_name} rejected state #{@state}")

  # `_change_state` will alter the state
  _change_state: (state) ->
    _log(@response_queue_name, "#{@state} -> #{state}")
    @state = state

  #
  # #### Connection Management
  #

  # `get_connection` returns a promise for the connection,
  # it creates the connection if it does not exist
  #
  # This function will raise an exception if state is not `started` or `starting`
  #
  # It will remove the connection if it sends a `error` or `close` event.
  get_connection: ->
    @_assert_state(['started', 'starting'])
    return @_connection if @_connection

    @_connection = amqp.connect(@amqp_uri)
    .then((connection) =>
      connection.on('error', (error) =>
        _log_error(@response_queue_name, "AMQP Error connection error", error)
        @_connection = null
      )
      connection.on('close', =>
        @_connection = null
      )
      connection
    )

  # `get_service_channel` returns a promise for the service channel,
  # it creates the channel if it does not exist
  #
  # This function will raise exception if state is not `started` or `starting` or `stopping`
  #
  # It sets the channels `prefetch` to `20` which will retrieve 20 messages from the queue at a time.
  # `20` is the size recommended from
  # [this](http://www.mariuszwojcik.com/2014/05/19/how-to-choose-prefetch-count-value-for-rabbitmq/) post.
  #
  # It will pass any returned messages to the `returned_handler`.
  #
  # If the channel has an error or closes it will clear the channel
  # and restart it if it is meant to be running.
  #
  # This method also creates the queues that the service requires, the service_queue and the response_queue.
  get_service_channel: ->
    @_assert_state(['started','starting','stopping'])
    return @_service_channel if @_service_channel
    @_service_channel = @get_connection()
    .then( (connection) =>
      connection.createChannel()
    )
    .then( (service_channel) =>
      service_channel.prefetch 20

      service_channel.on('return', (message) =>
        _log(@response_queue_name, "Message Returned to Channel")
        @returned_handler(message)
      )

      service_channel.on('error', (error) =>
        _log_error(@response_queue_name, "Service Channel Errored", error)
        @_service_channel = null
      )

      service_channel.on('close', =>
        @_service_channel = null
        if @state == 'started'
          @restart()
      )

      queue_promises = []
      if @service_queue_name
        queue_promises.push @_create_service_queue(service_channel)

      if @response_queue_name
        queue_promises.push @_create_response_queue(service_channel)

      bb.all(queue_promises)
      .then( -> service_channel)
    )

  #
  # #### Queue Management
  #

  # `_create_response_queue` takes the service channel and creates the response queue
  _create_response_queue: (service_channel) ->
    service_channel.assertQueue(@response_queue_name, {exclusive: true})
    .then( (response_queue) =>
      service_channel.consume(@response_queue_name, @_create_response_queue_function(service_channel))
    )

  # `_create_response_queue_function` creates the function that consumes the response queue
  #
  # The response queue function immediately acks the message as no other service consumes this
  # queue. This means if so if an error occurs in the
  # `response_handler` function the the message will still be removed from the queue
  _create_response_queue_function: (service_channel) =>
    return (msg) =>
      service_channel.ack(msg)
      @response_handler(msg)

  # `_create_service_queue` takes the service channel and creates the service queue
  _create_service_queue: (service_channel) ->
    service_channel.assertQueue(@service_queue_name, {durable: true})
    .then( =>
      service_channel.consume(@service_queue_name, @_create_service_queue_function(service_channel))
    )
    .then( (ret) =>
      @_service_queue_consumer_tag = ret.consumerTag
    )

  # `_create_service_queue_function` creates the function that consumes the service queue
  #
  # The service queue is where the services processing occurs.
  # This processing can have the potential to:
  # 1. succeed and return a message
  # 2. throw an unknown error
  # 3. throw a NAckError error
  # 4. be killed or die while processing the message (e.g. the tin restarts)
  #
  # Under these conditions this function will:
  # 1. ack the message (happy path)
  # 2. log an error error then ack the message
  # 3. log the error then nack the message so it will be retried, **this is very dangerous** see Errors section
  # 4. cause the service channel to die which nacks the message (so it will be retired)
  #
  _create_service_queue_function: (service_channel) ->
    return (msg) =>

      @processing_messages[msg.properties.messageId] = bb.try( => @service_handler(msg))
      .then( ->
        service_channel.ack(msg)
      )
      .catch(Service.NAckError, (err) ->
        _log_error @response_queue_name, "NACKed MESSAGE", err
        service_channel.nack(msg)
      )
      .catch( (err) ->
        _log_error @response_queue_name,"Service Channel Error", err
        service_channel.ack(msg)
      )
      .finally( =>
        delete @processing_messages[msg.properties.messageId]
      )

  #
  # #### Sending Messages
  #

  # `publish_message` publish a message to a queue
  publish_message: (exchange, routing_key, message, options) ->
    @get_service_channel()
    .then( (service_channel) =>
      service_channel.publish(exchange, routing_key, message, options)
    )


# ## Errors

# **NAckError**
#
# The `NAckError` can be thrown from a Service while it is processing a message to cause the message
# to be put back on the service queue for processing later.
#
# This is very dangerous and should be used only if necessary because if the message itself caused the
# error then it will be always be put back on the queue, and cause the service to process it indefinitely.
# If a message is malformed or malicious it is better for a service to swallow the message and log, rather than NAck,
# however if the cuase of the error is external (e.g. a database connection error) a NAckError will let the message be processed at a more reasonable time.

class NAckError extends Error
  constructor: () ->
    @name = "NAckError"
    @message = "NAck the Message"
    Error.captureStackTrace(this, NAckError)
Service.NAckError = NAckError


# **MessageNotDeliveredError**
#
# The `MessageNotDeliveredError` is thrown by the service if a sent message is [returned](https://www.rabbitmq.com/semantics.html) by RabbitMQ.
# This allows a service implementation to handle if a message is sent to a service queue that does not exist.
# This is like a 404 in HTTP, i.e. the service you are messaging does not exist.

class MessageNotDeliveredError extends Error
  constructor: (messageID, routingKey) ->
    @name = "MessageNotDeliveredError"
    @message = "message #{messageID} not delivered to #{routingKey}"
    Error.captureStackTrace(this, MessageNotDeliveredError)
Service.MessageNotDeliveredError = MessageNotDeliveredError


# **TimeoutError**
#
# The `TimeoutError` is thrown when a message being sent to a service takes too long.
# How long it will take to timeout a message can be altered, but this means that:
# 1. the service took to long to process the message
# 2. the service never got to process the message because it is still processing other messages
# 3. the service tried to process the message and errored without replying
# 4. the service queue exists, but no service is listening to it
#
# This error is important to handle because of under heavy load this will be the most likely error thrown.
# Also, given that it can be thrown even though a message has been processed means this is another reason to ensure idempotent messages.
Service.TimeoutError = bb.TimeoutError


# ## Logging Functions

# `log(uuid, message)` writes consistent log messages to stdout
_log = (uuid, message) ->
  console.log "#{(new Date()).toISOString()} - #{uuid} - #{message}"

# `_log_error(uuid, message, error)` writes consistent error messages to stderr
_log_error = (uuid, message, error = {stack: ''}) ->
  console.error "#{(new Date()).toISOString()} - #{uuid} - #{message} - #{error.stack}"

# `_log_message_error(uuid, message, msg)` writes consistent rabbitmq msg errors to stderr
_log_message_error = (uuid, message, msg) ->
  console.error "#{(new Date()).toISOString()} - #{uuid} - #{message} - messageID: '#{msg.properties.messageId}',
      correlationId: '#{msg.properties.correlationId}'
      type: '#{msg.properties.type}'
  "

module.exports = Service
