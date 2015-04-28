bb = require "bluebird"
amqp = require("amqplib")
_ = require('underscore')

class ServiceConnectionManager

  constructor: (@ampq_uri, @service_queue_name, @service_handler, @response_queue_name, @response_handler) ->

  start: ->
    # If queue names are not nil then they are created
    console.info "Starting #{@service_queue_name} service"
    amqp.connect(@ampq_uri)
    .then((connection) =>
      @connection = connection
      @connection.on('error', (error) =>
        console.log "AMQP connection error"
        console.error error
        throw error
      )
      @connection.createChannel()
    )
    .then( (serviceChannel) =>
      @serviceChannel = serviceChannel
      @serviceChannel.prefetch 256
      if @response_queue_name
        #console.log "create response queue #{@response_queue_name}"
        @serviceChannel.assertQueue(@response_queue_name, {exclusive: true, autoDelete: true})
      else
        false
    )
    .then( (response_queue) =>
      if @response_queue_name
        @response_queue = response_queue
        @serviceChannel.consume(@response_queue_name, @respondToMessage)
      else
        false
    )
    .then( =>
      if @service_queue_name
        #console.log "create service queue #{@service_queue_name}"
        @serviceChannel.assertQueue(@service_queue_name, {durable: false}) 
      else
        false
    )
    .then( (service_queue) =>
      if @service_queue_name
        @service_queue = bb.promisifyAll(service_queue)
        @serviceChannel.consume(@service_queue_name, @processMessage)
      else
        false
    )
    .then( =>
      #console.log "Started #{@uuid} service"
      @
    )

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
    @serviceChannel.ack(message)   

  sendMessage: (queue, payload, options) ->
    try
      bb.try( => @serviceChannel.publish('', queue, payload, options))
    catch error
      bb.try( -> 
        console.error "@sendMessage ERROR"
        throw error
      )


module.exports = ServiceConnectionManager
