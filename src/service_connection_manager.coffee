bb = require "bluebird"
amqp = require("amqplib")
_ = require('underscore')

class ServiceConnectionManager

  log : (message) ->
    console.log "#{(new Date()).toISOString()} - #{@uuid} - #{message}"

  constructor: (@ampq_uri, @uuid, @service_queue_name, @service_handler, @response_queue_name, @response_handler) ->
    @state = 'stopped' # two states 'started' and 'stopped'

  get_service_channel: ->
    return @_service_channel if @_service_channel
    @log "starting service"
    
    #close connection if still open
    @connection.close() if @connection
    @connection = null

    @_service_channel = amqp.connect(@ampq_uri)
    .then((connection) =>
      connection.on('error', (error) =>
        @log("AMQP Error connection error - #{error}")
      )

      connection.on('close', =>
        @_service_channel = null
        @connection = null #connection closed
        if @state == 'started'
          @log "AMQP Connection closed, restarting service" 
          #then restart
          @get_service_channel()
        else 
          @log "Connection closed" 
          #dont restart
      )

      @connection = connection
      connection.createChannel()
    )
    .then( (service_channel) =>
      # http://www.mariuszwojcik.com/2014/05/19/how-to-choose-prefetch-count-value-for-rabbitmq/
      # prefetch will grab a number of un ack'ed messages from the queue
      # since basically the first thing we do is ack a message this number can be quite low
      service_channel.prefetch 20

      service_channel.on('error', (error) =>
        @log "Service Channel Errored #{error}"
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
      fn = (msg) =>
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
      fn = (msg) =>
        #console.log @uuid, "recieved service message ID `#{msg.properties.messageId}`"
        service_channel.ack(msg)
        @service_handler(msg)

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
    @get_service_channel()
    .then( (sc) =>
      @connection.close()
    )

  sendMessage: (queue, payload, options) ->
    @get_service_channel()
    .then( (service_channel) ->
      service_channel.publish('', queue, payload, options)
    )

module.exports = ServiceConnectionManager
