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
      exists = false
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
    it 'should handle when stop start', ->
      hello_service = new Service('hellowworldservice',
        service_fn: (payload) -> 
          console.log 2;
          bb.delay(500).then( -> console.log 5; {body: {hello: "world"}})
      )

      service = new Service('testService', {timeout: 5000})
      
      bb.all([hello_service.start(), service.start()])
      .then( ->
        bb.delay(250) #enough time to put message on queue
        .then( ->
          #close connection
          console.log 3
          service.stop()
          .then( ->
            console.log 4
            service.start()
          )
        )
        console.log 1    
        service.sendMessage('hellowworldservice', {})
      )
      .spread( (msg, content) ->
        console.log 6
        expect(content.body.hello).to.equal('world')
      )
      .catch( (err) ->
        console.log err.stack
      )
      .finally(
        -> bb.all([service.stop(), hello_service.stop()])
      )

    it 'should auto resart', ->
      hello_service = new Service('hellowworldservice',
        service_fn: (payload) -> 
          console.log 2;
          bb.delay(500).then( -> console.log 5; {body: {hello: "world"}})
      )

      service = new Service('testService', {timeout: 5000})
      
      bb.all([hello_service.start(), service.start()])
      .then( ->
        bb.delay(250) #enough time to put message on queue
        .then( ->
          #force close connection
          console.log 3
          service.connection_manager.connection.close()
          .then( ->
            console.log 4
          )
        )
        console.log 1    
        service.sendMessage('hellowworldservice', {})
      )
      .spread( (msg, content) ->
        console.log 6
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
          {body: {hello: "world"}}
      )

      service = new Service('testService', {timeout: 1000})
      
      bb.all([hello_service.start(), service.start()])
      .then( ->
        pms = []
        for i in [1..100]
          pms.push service.sendMessage('hellowworldservice', {})
        #force close connection
        service.connection_manager.get_service_channel()
        .then( (sc) ->
          cn = "auto_delete_queue#{Math.random()}"
          sc.checkQueue(cn)
        )
        bb.all(pms)
      )
      .finally(
        -> bb.all([service.stop(), hello_service.stop()])
      )


    it 'should recover from connection error while recieveing messages', ->
      hello_service = new Service('hwservice',
        service_fn: (payload) ->
          bb.delay(10).then( ->
            {body: {hello: "world"}}
          )
      )

      service = new Service('tservice', {timeout: 2000})
      
      bb.all([hello_service.start(), service.start()])
      .then( ->
        pms = []
        for i in [1..1000]
          pms.push service.sendMessage('hwservice', {})
        #force close connection
        service.connection_manager.get_connection()
        .delay(10)
        .then( (con) ->
          console.log "KILL KILL KILL"
          con.connection.stream.end() #simulate unexpected disconnection
        )

        bb.all(pms)
      )
      .finally(
        -> bb.all([service.stop(), hello_service.stop()])
      )

    it 'should recover from connection error and all messages should be successful', ->
      hello_service = new Service('hwservice',
        service_fn: (payload) ->
          bb.delay(10).then( ->
            {body: {hello: "world"}}
          )
      )

      service = new Service('tservice', {timeout: 2000})
      
      bb.all([hello_service.start(), service.start()])
      .then ( ->
        service.sendMessage('hwservice', {})
      )
      .then( ->
        service.connection_manager.get_connection()
        .then( (con) ->
          console.log "KILL KILL KILL"
          con.connection.stream.end() #simulate unexpected disconnection
        )
      )
      .then( ->
        service.sendMessage('hwservice', {})
      )
      .finally(
        -> bb.all([service.stop(), hello_service.stop()])
      )