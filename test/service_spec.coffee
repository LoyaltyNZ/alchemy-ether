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
    it 'should process the messages then stop', ->
      recieved_message = false
      service = new Service('testService')
      long_service = new Service('hellowworldservice',
        service_fn: (payload) ->
          console.log "PAYLOAD", payload
          recieved_message = true
          bb.delay(50).then( -> {body: 'long'})
      )

      bb.all([long_service.start(), service.start()])
      .then( ->
        bb.delay(10).then( -> long_service.stop())
        service.sendMessage('hellowworldservice', {})

      )
      .spread( (resp, content) ->
        console.log content
        expect(recieved_message).to.equal true
        expect(content.body).to.equal 'long'
        expect(long_service.connection_manager.state).to.equal 'stopped'
      )
      .finally(-> service.stop())

    it 'should stop receiving messages while it is stopping', ->

  describe '#kill', ->
    it 'should not process the messages then stop', ->
      recieved_message = false
      service = new Service('testService', {timeout: 200})
      long_service = new Service('hellowworldservice',
        service_fn: (payload) ->
          recieved_message = true
          bb.delay(100).then( -> {message: 'long'})
      )

      bb.all([long_service.start(), service.start()])
      .then( ->
        bb.delay(50).then( -> long_service.kill())
        service.sendMessage('hellowworldservice', {})
      )
      .then( ->
        throw "SHOULD NOT GET HERE"
      )
      .catch( (e) ->
        expect(recieved_message).to.equal true
        expect(long_service.connection_manager.state).to.equal 'dead'
      )
      .finally(-> service.stop())
    it 'should not ack the messages being currently processed', ->

    it 'should die and not be startable again', ->

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


  describe '#sendRawMessage', ->
    it 'should work', ->
      service = new Service('push')
      s1 = new Service('pull')
      bb.all([service.start(), s1.start()])
      .then( ->
        service.sendRawMessage('pull', {}, {})
      )
      .finally( -> bb.all([service.stop(), s1.stop()]))


  describe '#sendMessage', ->

    describe 'returned transaction promise', ->
      it 'should contain a messageId', ->
        service = new Service('testService')
        service.start()
        .then( ->
          transaction_promise = service.sendMessage('service1', {})
          expect(transaction_promise.messageId).to.not.be.undefined
        )
        .finally( -> service.stop())

      it 'should use the x-interaction-id header if present', ->
        service = new Service('testService')
        service.start()
        .then( ->
          x_interaction_id = Util.generateUUID()
          payload =
            headers: { 'x-interaction-id': x_interaction_id }
          transaction_promise = service.sendMessage('service1', payload)
          expect(transaction_promise.transactionId).to.equal(x_interaction_id)
        )
        .finally( -> service.stop())

      it 'should generate a transaction id if one is missing', ->
        service = new Service('testService')
        service.start()
        .then( ->
          transaction_promise = service.sendMessage('service1', {})
          expect(transaction_promise.transactionId).to.not.be.undefined
        )
        .finally( -> service.stop())

      it 'should send the provided x-interaction-id header if present', ->
        x_interaction_id = Util.generateUUID()

        service  = new Service('testService')
        receivingService = new Service('receivingService', service_fn: (pl) ->
          expect(pl.headers['x-interaction-id']).to.equal(x_interaction_id)
          return { body: { "successful": true } }
        )

        bb.all([service.start(), receivingService.start()])
        .then( ->
          payload =
            headers: { 'x-interaction-id': x_interaction_id }
          service.sendMessage('receivingService', payload)
        ).spread( (msg, body) ->
          expect(body.body.successful).to.be.true
        )
        .finally( -> bb.all([service.stop(), receivingService.stop()]) )

      it 'should send a generated x-interaction-id header none is passed', ->
        service  = new Service('testService')
        receivingService = new Service('receivingService', service_fn: (pl) ->
          expect(pl.headers['x-interaction-id']).to.not.be.undefined
          return {body: { "successful": true }}
        )

        bb.all([service.start(), receivingService.start()])
        .then( ->
          service.sendMessage('receivingService', {})
        ).spread( (msg, body) ->
          expect(body.body.successful).to.be.true
        )
        .finally( -> bb.all([service.stop(), receivingService.stop()]) )

    describe 'transactions queue', ->


      it 'should add a transaction to the deferred transactions', ->
        service = new Service('testService', timeout: 10)
        service.start()
        .then( ->
          expect(Object.keys(service.transactions).length).to.equal(0)
          service.sendMessage('service1', {})
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
          service.sendMessage('hellowworldservice', {})
        )
        .spread( (msg, content) ->
          expect(content.body.hello).to.equal('world')
          expect(Object.keys(service.transactions).length).to.equal(0)
        )
        .finally(
          -> bb.all([service.stop(), hello_service.stop()])
        )

      it 'should timeout when no message is returned and remove transaction deferred', ->
        service = new Service('testService', timeout: 1)
        service.start()
        .then( ->
          service.sendMessage('service1', {})
          .then( ->
            throw "It should not get here"
          )
          .catch(Service.TimeoutError, (err) ->
            expect(Object.keys(service.transactions).length).to.equal(0)
          )
        )
        .finally( -> service.stop())

  describe "option responce_queue", ->
    it 'should not listen to a service queue if false', ->
      hello_service = new Service('hellowworldservice',
        timeout: 10,
        responce_queue: false,
        service_fn: (payload) -> {body: {hello: "world"}}
      )

      service = new Service('testService')

      bb.all([hello_service.start(), service.start()])
      .then( ->
        service.sendMessage('hellowworldservice', {})
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
        service.sendMessage('hellowworldservice', {})
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
        service.sendMessage('hellowworldservice', {})
      )
      .spread( (msg, content) ->
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
        service.sendMessage('hellowworldservice', {})
      )
      .spread( (msg, content) ->
        expect(content.body.hello).to.equal('world')
        expect(content.status_code).to.equal(201)
        expect(Object.keys(service.transactions).length).to.equal(0)
      )
      .finally(
        -> bb.all([service.stop(), hello_service.stop()])
      )



  describe "unhappy path", ->

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
        service.sendMessage('bad_service', {}) #kill the service
      )
      .then( ->
        expect(recieved_messages).to.equal 1
        service.sendMessage('bad_service', {})
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
          console.log "THAT"
          {}
      )

      bb.all([dead_service.start(), service.start()])
      .then( ->
        service.sendMessage('hellowworldservice', {})
        bb.delay(100).then( -> dead_service.stop())
      )
      .then( ->
        good_service.start().delay(10) # should get the message that was lost after a bit
      )
      .then( ->
        expect(recieved_first_time).to.equal true
        expect(recieved_second_time).to.equal false
      )
      .finally(
        -> bb.all([service.stop(), good_service.stop()])
      )

    it 'should not lose the message if a worker dies', ->
      recieved_first_time = false
      recieved_second_time = false
      dead_service = new Service('hellowworldservice',
        service_fn: (payload) ->
          recieved_first_time = true
          console.log "WHO"
          return bb.delay(200) #will wait for a bit while I kill it
      )

      service = new Service('testService', {timeout: 5000})
      good_service = new Service('hellowworldservice',
        service_fn: (payload) ->
          recieved_second_time = true
          console.log "THIS"
          {}
      )

      bb.all([dead_service.start(), service.start()])
      .then( ->
        service.sendMessage('hellowworldservice', {})
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
          console.log "HERE"
          bb.delay(500).then( -> console.log 'THERE'; {body: {hello: "world2"}})
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
        service.sendMessage('hellowworldservice', {})
      )
      .spread( (msg, content) ->
        console.log "should be world2", content.body
        expect(content.body.hello).to.equal('world2')
      )
      .finally(
        -> bb.all([service.stop(), hello_service.stop()])
      )

    it 'should auto resart', ->
      hello_service = new Service('hellowworldservice',
        service_fn: (payload) ->
          console.log "HERE"
          bb.delay(500).then( -> console.log "THERE"; {body: {hello: "world1"}})
      )

      service = new Service('testService', {timeout: 5000})

      bb.all([hello_service.start(), service.start()])
      .then( ->
        service.sendMessage('hellowworldservice', {})
      )
      .spread( (msg, content) ->
        console.log "should be world1", content.body
        expect(content.body.hello).to.equal('world1')

        service.connection_manager.get_service_channel()
        .then( (sc) ->
          cn = "auto_delete_queue#{Math.random()}"
          sc.checkQueue(cn)
        )
        .catch( (e) ->
          console.log e, e.stack, "BAD SERVICE CHANNEL ERROR"
        )
        .delay(100) #enough time to restart
      )
      .then( ->
        service.sendMessage('hellowworldservice', {})
      )
      .spread( (msg, content) ->
        console.log "content", content
        expect(content.body.hello).to.equal('world1')
      )
      .finally(
        -> bb.all([service.stop(), hello_service.stop()])
      )
