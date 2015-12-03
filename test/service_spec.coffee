describe 'Service', ->

  describe '#constructor', ->
    it 'should successfully construct', ->
      service = new Service("testService")


  describe '#start', ->
    it 'should successfully start', ->
      service = new Service("testService")
      service.start()
      .then(->
        service.stop()
      )

    it 'should start stop then start', ->
      service = new Service("testService")
      service.start()
      .then(->
        console.log "started 1"
        service.stop()
      )
      .then(->
        console.log "stopped 1"
        service.start()
      )
      .then(->
        console.log "started 2"
        service.stop()
      )
      .then(->
        console.log "stopped 2"
      )

    it 'should break if uri is bad', ->
      service = new Service("testService", ampq_uri: 'bad_uri')
      expect(service.start()).to.be.rejected


  describe '#stop', ->
    it 'should process the outgoing messages then stop', ->
      recieved_message = false
      service = new Service('testService')
      long_service = new Service('hellowworldservice',
        service_fn: (payload) ->
          recieved_message = true
          bb.delay(50).then( -> {body: 'long'})
      )

      bb.all([long_service.start(), service.start()])
      .then( ->
        bb.delay(10).then( -> service.stop())
        service.send_message_to_service('hellowworldservice', {})
      )
      .delay(100)
      .then( (content) ->
        expect(recieved_message).to.equal true
        expect(content.body).to.equal 'long'
        expect(service.connection_manager.state).to.equal 'stopped'
      )
      .finally(-> long_service.stop())

    it 'should process the incoming messages then stop', ->
      recieved_message = false
      service = new Service('testService')
      long_service = new Service('hellowworldservice',
        service_fn: (payload) ->
          recieved_message = true
          bb.delay(50).then( -> {body: 'long'})
      )

      bb.all([long_service.start(), service.start()])
      .then( ->
        bb.delay(10).then( -> long_service.stop())
        service.send_message_to_service('hellowworldservice', {})
      )
      .delay(100)
      .then( (content) ->
        expect(recieved_message).to.equal true
        expect(content.body).to.equal 'long'
        expect(long_service.connection_manager.state).to.equal 'stopped'
      )
      .finally(-> service.stop())

    it 'should stop receiving messages while it is stopping', ->
      recieved_messages = 0
      service = new Service('testService')
      long_service = new Service('stoppedhellowworldservice',
        service_fn: (payload) ->
          recieved_messages++
          bb.delay(50).then( -> {body: 'long'})
      )

      short_service = new Service('stoppedhellowworldservice')

      bb.all([long_service.start(), service.start()])
      .then( ->

        bb.delay(10)
        .then( ->
          long_service.stop()
        )
        .delay(10)
        .then( ->
          service.send_message_to_service('stoppedhellowworldservice', {})
        )
        service.send_message_to_service('stoppedhellowworldservice', {})

      )
      .delay(100)
      .then( (content) ->
        expect(recieved_messages).to.equal 1
        expect(content.body).to.equal 'long'
        expect(long_service.connection_manager.state).to.equal 'stopped'
      )
      .finally( ->
        short_service.start() #drain the queue
        .then( ->
          bb.all([short_service.stop(), service.stop()])
        )
      )

  describe '#kill', ->
    it 'should not process the messages, and not ack them then stop', ->
      recieved_message = false
      retrieved_message = false
      service = new Service('testService', {timeout: 200})

      long_service = new Service('deadhellowworldservice',
        service_fn: (payload) ->
          console.log "HERE"
          recieved_message = true
          bb.delay(200).then( -> {body: "first_chance"})
      )

      short_service = new Service('deadhellowworldservice',
        service_fn: (payload) ->
          console.log "HEREEee"
          retrieved_message = true
          {body: "second_chance"}
      )

      bb.all([long_service.start(), service.start()])
      .then( ->
        bb.delay(10)
        .then( -> long_service.kill())
        .delay(10)
        .then( -> short_service.start())

        service.send_message_to_service('deadhellowworldservice', {})
      )
      .then( (body) ->
        expect(body.body).to.equal "second_chance"
        expect(retrieved_message).to.equal true
        expect(recieved_message).to.equal true
        expect(long_service.connection_manager.state).to.equal 'dead'
      )
      .finally(->
        bb.all([short_service.stop(), service.stop()])
      )

    it 'should die and not be startable again', ->
      service = new Service('testService', {timeout: 200})
      service.start()
      .then( ->
        service.kill()
      )
      .then( ->
        service.start().then( ->
          throw "SHOULD NOT GET HERE"
        )
      )
      .catch( (e) ->
        expect(service.connection_manager.state).to.equal 'dead'
      )


  describe 'response queue', ->
    response_queue_exists = (service) ->
      checker = new Service("service_queue_checker")
      exists = false
      checker.start()
      .then( ->
        checker.connection_manager.get_service_channel()
        .then( (sc) ->
          sc.checkQueue(service.response_queue_name)
        )
        .then( ->
          #will error out if it doesnt
          exists = true
        )
        .catch( ->
          exists = false
        )
      )
      .then( ->
        exists
      )
      .finally( ->
        if checker.connection_manager.state == 'started'
          checker.stop()
      )


    it 'should exist after creation', ->
      service = new Service("testService")
      exists = false
      service.start()
      .then(->
        response_queue_exists(service)
        .then( (ret) ->
          exists = ret
        )
      )
      .then( ->
        expect(exists).to.equal true
      )
      .finally( ->
        service.stop()
      )

    it 'should exist after no messages (as there is a consumer)', ->
      service = new Service("testService")
      exists = false
      service.start()
      .delay(2000)
      .then( ->
        response_queue_exists(service)
        .then( (ret) ->
          exists = ret
        )
      )
      .then( ->
        expect(exists).to.equal true
      )
      .finally( ->
        service.stop()
      )

    it 'should exist after stopping and restarting (if quick enough)', ->
      service = new Service("testService")
      exists = false
      service.start()
      .then(->
        service.stop()
      )
      .delay(100)
      .then( ->
        response_queue_exists(service)
        .then( (ret) ->
          exists = ret
        )
      )
      .then( ->
        expect(exists).to.equal true
      )

    it 'should not exist after stopping for a longer period of time', ->
      service = new Service("testService")
      exists = true
      service.start()
      .then(->
        service.stop()
      )
      .delay(2000)
      .then( ->
        response_queue_exists(service)
        .then( (ret) ->
          exists = ret
        )
      )
      .then( ->
        expect(exists).to.equal false
      )


  describe '#send_message', ->
    it 'should work', ->
      service = new Service('push')
      s1 = new Service('pull')
      bb.all([service.start(), s1.start()])
      .then( ->
        service.send_message('', 'pull', {}, {})
      )
      .finally( -> bb.all([service.stop(), s1.stop()]))


  describe '#send_message_to_service', ->

    describe 'returned transaction promise', ->
      it 'should contain a messageId', ->
        service = new Service('testService', timeout: 10)
        service.start()
        .then( ->
          transaction_promise = service.send_message_to_service('service1', {})
          expect(transaction_promise.messageId).to.not.be.undefined
        )
        .finally( -> service.stop())

      it 'should use the x-interaction-id header if present', ->
        service = new Service('testService', timeout: 10)
        service.start()
        .then( ->
          x_interaction_id = Service.generateUUID()
          payload =
            headers: { 'x-interaction-id': x_interaction_id }
          transaction_promise = service.send_message_to_service('service1', payload)
          expect(transaction_promise.transactionId).to.equal(x_interaction_id)
        )
        .finally( -> service.stop())

      it 'should generate a transaction id if one is missing', ->
        service = new Service('testService', timeout: 10)
        service.start()
        .then( ->
          transaction_promise = service.send_message_to_service('service1', {})
          expect(transaction_promise.transactionId).to.not.be.undefined
        )
        .finally( -> service.stop())

      it 'should send the provided x-interaction-id header if present', ->
        x_interaction_id = Service.generateUUID()

        service  = new Service('testService', timeout: 10)
        receivingService = new Service('receivingService', service_fn: (pl) ->
          expect(pl.headers['x-interaction-id']).to.equal(x_interaction_id)
          return { body: { "successful": true } }
        )

        bb.all([service.start(), receivingService.start()])
        .then( ->
          payload =
            headers: { 'x-interaction-id': x_interaction_id }
          service.send_message_to_service('receivingService', payload)
        ).then( (body) ->
          expect(body.body.successful).to.be.true
        )
        .finally( -> bb.all([service.stop(), receivingService.stop()]) )

      it 'should send a generated x-interaction-id header none is passed', ->
        service  = new Service('testService', timeout: 10)
        receivingService = new Service('receivingService', service_fn: (pl) ->
          expect(pl.headers['x-interaction-id']).to.not.be.undefined
          return {body: { "successful": true }}
        )

        bb.all([service.start(), receivingService.start()])
        .then( ->
          service.send_message_to_service('receivingService', {})
        ).then( (body) ->
          expect(body.body.successful).to.be.true
        )
        .finally( -> bb.all([service.stop(), receivingService.stop()]) )

    describe 'transactions queue', ->


      it 'should add a transaction to the deferred transactions', ->
        service = new Service('testService', timeout: 10)
        service.start()
        .then( ->
          expect(Object.keys(service.transactions).length).to.equal(0)
          service.send_message_to_service('service1', {})
          expect(Object.keys(service.transactions).length).to.equal(1)
        )
        .finally( -> service.stop())

      it 'should remove transaction after response', ->
        hello_service = new Service('hellowworldservice',
          timeout: 10,
          service_fn: (payload) -> {body: {hello: "world"}}
        )

        service = new Service('testService')

        bb.all([hello_service.start(), service.start()])
        .then( ->
          service.send_message_to_service('hellowworldservice', {})
        )
        .then( (content) ->
          expect(content.body.hello).to.equal('world')
          expect(Object.keys(service.transactions).length).to.equal(0)
        )
        .finally(
          -> bb.all([service.stop(), hello_service.stop()])
        )

      it 'should return a message when trying to deliver to service that doesnt exist', ->
        service = new Service('testService', timeout: 10)
        service.start()
        .then( ->
          service.send_message_to_service('service1', {})
          .then( ->
            throw "It should not get here"
          )
          .catch(Service.MessageNotDeliveredError, (err) ->
            expect(Object.keys(service.transactions).length).to.equal(0)
          )
        )
        .finally( -> service.stop())

      it 'should timeout message, so message is not read after timeout', ->
        read_message = false
        badservice = new Service('ts1', service_fn: -> read_message = true; {})
        service = new Service('testService', timeout: 100)
        bb.all([service.start(), badservice.start()])
        .then( ->
          badservice.stop()
        )
        .then( ->
          service.send_message_to_service('ts1', {})
          .then( ->
            throw "It should not get here"
          )
          .catch(Service.TimeoutError, (err) ->
            expect(Object.keys(service.transactions).length).to.equal(0)
          )
        )
        .then( ->
          badservice.start()
        )
        .delay(100)
        .then( ->
          expect(read_message).to.equal false
        )
        .finally( -> bb.all([service.stop(), badservice.stop()]))

      it 'should timeout when no message is returned and remove transaction deferred', ->
        badservice = new Service('ts1', service_fn: -> bb.delay(100))
        service = new Service('testService', timeout: 1)
        bb.all([service.start(), badservice.start()])
        .then( ->
          service.send_message_to_service('ts1', {})
          .then( ->
            throw "It should not get here"
          )
          .catch(Service.TimeoutError, (err) ->
            expect(Object.keys(service.transactions).length).to.equal(0)
          )
        )
        .finally( -> bb.all([service.stop(), badservice.stop()]))

  describe "option response_queue", ->
    it 'should not listen to a service queue if false', ->
      hello_service = new Service('hellowworldservice',
        timeout: 10,
        response_queue: false,
        service_fn: (payload) -> {body: {hello: "world"}}
      )

      service = new Service('testService')

      bb.all([hello_service.start(), service.start()])
      .then( ->
        service.send_message_to_service('hellowworldservice', {})
      )
      .finally(
        -> bb.all([service.stop(), hello_service.stop()])
      )


  describe "option service_queue", ->
    it 'should not listen to a service queue if false', ->
      hello_service = new Service('hellowworldservice',
        timeout: 10,
        service_queue: false,
        service_fn: (payload) -> {body: {hello: "world"}}
      )

      service = new Service('testService')

      bb.all([hello_service.start(), service.start()])
      .then( ->
        service.send_message_to_service('hellowworldservice', {})
        .then( ->
          throw "It should not get here"
        )
        .catch(Service.TimeoutError, (err) ->

        )
      )
      .finally(
        -> bb.all([service.stop(), hello_service.stop()])
      )

  describe "service_fn", ->
    it 'should work when returning a promise', ->
      hello_service = new Service('hellowworldservice',
        service_fn: (payload) -> bb.delay(10).then( -> {body: {hello: "world"}})
      )

      service = new Service('testService')

      bb.all([hello_service.start(), service.start()])
      .then( ->
        service.send_message_to_service('hellowworldservice', {})
      )
      .then( (content) ->
        expect(content.body.hello).to.equal('world')
        expect(Object.keys(service.transactions).length).to.equal(0)
      )
      .finally(
        -> bb.all([service.stop(), hello_service.stop()])
      )

    it "should be able to alter status", ->
      hello_service = new Service('hellowworldservice',
        service_fn: (payload) -> {body: {hello: "world"}, status_code: 201}
      )

      service = new Service('testService')

      bb.all([hello_service.start(), service.start()])
      .then( ->
        service.send_message_to_service('hellowworldservice', {})
      )
      .then( (content) ->
        expect(content.body.hello).to.equal('world')
        expect(content.status_code).to.equal(201)
        expect(Object.keys(service.transactions).length).to.equal(0)
      )
      .finally(
        -> bb.all([service.stop(), hello_service.stop()])
      )



  describe "unhappy path", ->

    it 'should nack the message if NAckError is thrown', ->
      recieved_first_time = false
      recieved_second_time = false
      dead_service = new Service('hellowworldservice',
        service_fn: (payload) ->
          recieved_first_time = true
          throw new Service.NAckError()
      )

      service = new Service('testService', {timeout: 5000})
      good_service = new Service('hellowworldservice',
        service_fn: (payload) ->
          recieved_second_time = true
          {}
      )

      bb.all([dead_service.start(), service.start()])
      .then( ->
        service.send_message_to_service('hellowworldservice', {})
      )
      .then( (content) ->
        expect(content.status_code).to.equal 500
        dead_service.stop()
      )
      .then( ->
        good_service.start().delay(50) # should get the message that was lost after a bit
      )
      .then( ->
        expect(recieved_first_time).to.equal true
        expect(recieved_second_time).to.equal true
      )
      .finally(
        -> bb.all([service.stop(), good_service.stop()])
      )

    it 'should not stop the service if the service_fn throws an error', ->
      recieved_messages = 0
      bad_service = new Service('bad_service',
        service_fn: (payload) ->
          recieved_messages++
          throw new Error()
      )
      service = new Service('testService')

      bb.all([bad_service.start(), service.start()])
      .then( ->
        service.send_message_to_service('bad_service', {}) #kill the service
      )
      .then( ->
        expect(recieved_messages).to.equal 1
        service.send_message_to_service('bad_service', {})
      )
      .then( ->
        expect(recieved_messages).to.equal 2
      )

    it 'should still ack if the service throws an error', ->
      recieved_first_time = false
      recieved_second_time = false
      dead_service = new Service('hellowworldservice',
        service_fn: (payload) ->
          recieved_first_time = true
          throw new Error()
      )

      service = new Service('testService', {timeout: 5000})
      good_service = new Service('hellowworldservice',
        service_fn: (payload) ->
          recieved_second_time = true
          {}
      )

      bb.all([dead_service.start(), service.start()])
      .then( ->
        service.send_message_to_service('hellowworldservice', {})
      )
      .then( (content) ->
        expect(content.status_code).to.equal 500
        dead_service.stop()
      )
      .then( ->
        good_service.start().delay(50) # should get the message that was lost after a bit
      )
      .then( ->
        expect(recieved_first_time).to.equal true
        expect(recieved_second_time).to.equal false
      )
      .finally(
        -> bb.all([service.stop(), good_service.stop()])
      )

    it 'should not lose the message (ack) if a worker dies', ->
      recieved_first_time = false
      recieved_second_time = false
      dead_service = new Service('hellowworldservice123',
        service_fn: (payload) ->
          recieved_first_time = true
          return bb.delay(200) #will wait for a bit while I kill it
      )

      service = new Service('testService', {timeout: 5000})
      good_service = new Service('hellowworldservice123',
        service_fn: (payload) ->
          recieved_second_time = true
          {}
      )

      bb.all([dead_service.start(), service.start()])
      .then( ->
        service.send_message_to_service('hellowworldservice123', {})
        bb.delay(100).then( -> console.log "KILL"; dead_service.stop())
      )
      .then( ->
        good_service.start().delay(10) # should get the message that was lost after a bit
      )
      .then( ->
        expect(recieved_first_time).to.equal true
        expect(recieved_second_time).to.equal true
      ).delay(1000)
      .finally(
        -> bb.all([service.stop(), good_service.stop()])
      )

    it 'should handle when stop start', ->
      hello_service = new Service('hellowworldservice',
        service_fn: (payload) ->
          bb.delay(500).then( -> {body: {hello: "world2"}})
      )

      service = new Service('testService', {timeout: 5000})

      bb.all([hello_service.start(), service.start()])
      .then( ->
        bb.delay(250) #enough time to put message on queue
        .then( ->
          #close connection
          service.stop()
          .then( ->
            service.start()
          )
        )
        service.send_message_to_service('hellowworldservice', {})
      )
      .then( (content) ->
        expect(content.body.hello).to.equal('world2')
      )
      .delay(100)
      .finally(
        -> bb.all([service.stop(), hello_service.stop()])
      )

    it 'should auto resart', ->
      hello_service = new Service('hellowworldservice',
        service_fn: (payload) ->
          bb.delay(500).then( -> {body: {hello: "world"}})
      )

      service = new Service('testService', {timeout: 5000})

      bb.all([hello_service.start(), service.start()])
      .then( ->
        bb.delay(250) #enough time to put message on queue
        .then( ->
          #force close connection
          service.connection_manager.connection.close()
        )
        service.send_message_to_service('hellowworldservice', {})
      )
      .then( (content) ->
        expect(content.body.hello).to.equal('world')
      )
      .catch( (err) ->
        console.log err.stack
      )
      .finally(
        -> bb.all([service.stop(), hello_service.stop()])
      )


    it 'should auto restart on service channel error and all messages should be successful', ->
      hello_service = new Service('hellowworldservice',
        service_fn: (payload) ->
          console.log "RECIEVED MESSAGE"
          bb.delay(500).then( -> console.log "REPLYING TO MESSAGE"; {body: {hello: "world"}})
      )

      service = new Service('testService', {timeout: 5000})

      bb.all([hello_service.start(), service.start()])
      .then( ->
        bb.delay(250) #enough time to put message on queue
        .then( ->
          service.connection_manager.get_service_channel()
          .then( (sc) ->
            cn = "auto_delete_queue#{Math.random()}"
            sc.checkQueue(cn)
          )
        )
        service.send_message_to_service('hellowworldservice', {})
      )
      .then( (content) ->
        expect(content.body.hello).to.equal('world')
      )
      .catch( (err) ->
        console.log err.stack
      )
      .finally(
        -> bb.all([service.stop(), hello_service.stop()])
      )



