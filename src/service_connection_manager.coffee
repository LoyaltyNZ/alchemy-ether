bb = require "bluebird"
amqp = require("amqplib")
_ = require('underscore')

class ServiceConnectionManager

  constructor: (@ampq_uri, @service_queue_name, @service_handler, @response_queue_name, @response_handler) ->

  get_service_channel: ->
    return @_service_channel if @_service_channel

    console.log "create service channel", @response_queue_name
    
    @_service_channel = amqp.connect(@ampq_uri)
    .then((connection) =>
      @connection = connection

      @connection.on('error', (error) =>
        console.log "AMQP connection error"
        console.error error
        @_service_channel = null
      )
      @connection.on('close', ->
        console.log "AMQP connection closed"
        @_service_channel = null
      )

      @connection.createChannel()
    )
    .then( (service_channel) =>

      service_channel.prefetch 256

      @create_response_queue(service_channel)
      .then( => @create_service_queue(service_channel))
      .then( -> service_channel)
    )
    .then( (service_channel) => 
      service_channel
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
    # If queue names are nil then they are not created
    try
      @get_service_channel()
    catch error
      bb.try( -> throw error) #turn actual error into promise error

  stop: -> 
    #console.log "Stopping #{@uuid} service"
    @connection.close()
    .then( =>
      #console.log "Stopped #{@uuid} service"
    )

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
