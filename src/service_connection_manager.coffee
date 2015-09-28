bb = require "bluebird"
amqp = require("amqplib")
_ = require('lodash')

class ServiceConnectionManager

  log : (message) ->
    console.log "#{(new Date()).toISOString()} - #{@uuid} - #{message}"

  constructor: (@ampq_uri, @uuid, @service_queue_name, @service_handler, @response_queue_name, @response_handler, @returned_handler) ->
    @state = 'stopped' # two states 'started' and 'stopped'

  get_connection: ->
    return @_connection if @_connection
    @log "creating connection"
    @_connection = amqp.connect(@ampq_uri)
    .then((connection) =>
      @log "created connection"
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
    return @_service_channel if @_service_channel
    @log "creating service channel"

    @_service_channel = @get_connection()
    .then( (connection) =>
      connection.createChannel()
    )
    .then( (service_channel) =>
      @log "created service channel"
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
        @log "Service Channel Closed"
        @_service_channel = null
        if @state == 'started'
          @log "AMQP Service Channel closed, restarting service"
          #then restart
          @get_service_channel()
        else
          @log "Service Channel stopped"
          #dont restart
      )

      @create_response_queue(service_channel)
      .then( => @assert_logging_exchange(service_channel))
      .then( => @create_service_queue(service_channel))
      .then( -> service_channel) #return the service channel
    )

  assert_logging_exchange: (service_channel) ->
    service_channel.assertExchange("logging.exchange", 'fanout')

  create_response_queue: (service_channel) ->
    if @response_queue_name
      @log "Creating response queue"
      fn = (msg) =>
        #@log "recieved response message ID `#{JSON.stringify(msg.properties)}`"
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
      @log "Creating service queue"
      fn = (msg) =>
        #@log "recieved service message ID `#{msg.properties.messageId}`"
        service_channel.ack(msg)
        @service_handler(msg)

      service_channel.assertQueue(@service_queue_name, {durable: false})
      .then( =>
        service_channel.assertExchange("resources.exchange", 'topic')
      )
      .then( =>
        service_channel.consume(@service_queue_name, fn)
      )
    else
      bb.try( -> )

  start: ->
    @state = 'started'
    # If queue names are nil then they are not created
    try
      @get_service_channel()
    catch error
      bb.try( -> throw error) #turn actual error into promise error

  stop: ->
    return bb.try(->) if @state == 'stopped'
    @state = 'stopped'
    @get_connection()
    .then( (connection) =>
      connection.close()
    )


  addResourceToService: (resource_topic) ->
    @get_service_channel()
    .then( (service_channel) =>
      service_channel.bindQueue(@service_queue_name, "resources.exchange", resource_topic)
    )
    .then( =>
      @log "Bound #{resource_topic} to resources.exchange"
    )

  sendMessageToService: (service, payload, options) ->
    @get_service_channel()
    .then( (service_channel) =>
      options.mandatory = true if options.type == 'http_request'
      service_channel.publish('', service, payload, options)
    )

  sendMessageToResource: (resource, payload, options) ->
    @get_service_channel()
    .then( (service_channel) =>
      options.mandatory = true
      service_channel.publish("resources.exchange", resource, payload, options)
    )


  addServiceToLoggingExchange: () ->
    @get_service_channel()
    .then( (service_channel) =>
      service_channel.bindQueue(@service_queue_name, "logging.exchange", '')
    )
    .then( =>
      @log "Bound #{@service_queue_name} to logging.exchange"
    )

  removeServiceToLoggingExchange: () ->
    @get_service_channel()
    .then( (service_channel) =>
      service_channel.unbindQueue(@service_queue_name, "logging.exchange", '')
    )
    .then( =>
      @log "Unbound #{@service_queue_name} to logging.exchange"
    )

  logMessage: (payload, options) ->
    @get_service_channel()
    .then( (service_channel) =>
      service_channel.publish("logging.exchange", '', payload, options)
    )

  logMessageToService: (service, payload, options) ->
    @get_service_channel()
    .then( (service_channel) =>
      service_channel.publish('', service, payload, options)
    )

module.exports = ServiceConnectionManager
