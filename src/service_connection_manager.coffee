bb = require "bluebird"
amqp = require("amqplib")
_ = require('underscore')

class ServiceConnectionManager

  constructor: (@ampq_uri, @uuid, @service_queue_name, @service_handler, @response_queue_name, @response_handler) ->
    @state = 'stopped' # two states 'started' and 'stopped'

  get_service_channel: ->
    return @_service_channel if @_service_channel
    console.log "starting service #{@uuid}"
    
    @_service_channel = amqp.connect(@ampq_uri)
    .then((connection) =>

      connection.on('error', (error) =>
        console.log "AMQP Error connection error"
        console.error error
      )

      connection.on('close', =>
        @_service_channel = null
        @connection = null
        if @state == 'started'
          console.log "AMQP connection closed, restarting service #{@uuid}" 
          #then restart
          @get_service_channel()
        else 
          console.log "Service stopped #{@uuid}" 
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

      @create_response_queue(service_channel)
      .then( => @create_service_queue(service_channel))
      .then( -> service_channel) #return the service channel
    )

  create_response_queue: (service_channel) ->
    if @response_queue_name
      #console.log "create response queue #{@response_queue_name}"
      service_channel.assertQueue(@response_queue_name, {exclusive: true, autoDelete: true})
      .then( (response_queue) =>
        service_channel.consume(@response_queue_name, @respondToMessage)
      )
    else
      bb.try( -> )

  create_service_queue: (service_channel) ->
    if @service_queue_name
      service_channel.assertQueue(@service_queue_name, {durable: false})
      .then( => 
        service_channel.consume(@service_queue_name, @processMessage)
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
    @connection.close()


  respondToMessage: (msg) =>
    @_acknowledge(msg)
    @response_handler(msg)

  processMessage: (msg) =>
    @_acknowledge(msg)
    @service_handler(msg)

  _acknowledge: (message) =>
    @get_service_channel()
    .then( (service_channel) ->
      service_channel.ack(message)
    )

  sendMessage: (queue, payload, options) ->
    @get_service_channel()
    .then( (service_channel) ->
      service_channel.publish('', queue, payload, options)
    )

module.exports = ServiceConnectionManager
