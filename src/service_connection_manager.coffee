bb = require "bluebird"
amqp = require("amqplib")
_ = require('lodash')

class ServiceConnectionManager

  log : (message) ->
    console.log "#{(new Date()).toISOString()} - #{@uuid} - #{message}"

  constructor: (@ampq_uri, @uuid, @service_queue_name, @service_handler, @response_queue_name, @response_handler) ->
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
        @log "Service Channel Errored #{error}"
        @_service_channel = null
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
      .then( => @create_service_queue(service_channel))
      .then( -> service_channel) #return the service channel
    )

  create_response_queue: (service_channel) ->
    if @response_queue_name
      @log "Creating response queue"
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
      @log "Creating service queue"
      fn = (msg) =>
        # @log "recieved service message ID `#{msg.properties.messageId}`"
        #
        # Conditions
        # 1. The Service Function Succeeds
        # 2. The Service Function Errors
        # 3. The Service is killed or dies while processing the message

        # 1. will ack the message
        # 2. will log the error, ack the message, then propagate the error (which may kill the service)
        # 3. will cause the service channel to die which will not ack the message
        #
        bb.try( => @service_handler(msg))
        .then( (ret) ->
          service_channel.ack(msg)
          ret
        )
        .catch( (e) ->
          service_channel.ack(msg)
          console.error e
          throw e
        )

      service_channel.assertQueue(@service_queue_name, {durable: false})
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

  sendMessage: (queue, payload, options) ->
    @get_service_channel()
    .then( (service_channel) =>
      #@log "sending message ID `#{options.messageId}` writable #{service_channel.connection.stream.writable}"
      published = service_channel.publish('', queue, payload, options)
      #@log "#{published}"
      published
    )

module.exports = ServiceConnectionManager
