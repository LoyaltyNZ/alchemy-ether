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

    it 'should break if uri is bad', ->
      service = new Service("testService", ampq_uri: 'bad_uri')
      expect(service.start()).to.be.rejected

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
        timeout: 10, 
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
        timeout: 10, 
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

