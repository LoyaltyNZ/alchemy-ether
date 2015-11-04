describe "Resource", ->
  describe "start stop", ->
    it 'should work', ->
      resource = new Resource("testResource")
      resource.start()
      .then(->
        resource.stop()
      )


  describe "show", ->
    it 'should work', ->
      service = new Service('testService')
      resource = new Resource("testResource")
      resource.check_privilages = -> true
      resource.show = (payload) ->
        return {body: {"hello": "world"}}

      bb.all([service.start(), resource.start()])
      .then( ->
        service.sendMessage('testResource', {verb: "GET"})
      )
      .spread((resp, body) ->
        expect(body.body.hello).to.equal "world"
        expect(body.status_code).to.equal 200
      )
      .finally(->
        bb.all([service.stop(), resource.stop()])
      )

    describe "logging", ->

      it 'should log 2 (inbound and outbound) messages', ->
        service = new Service('testService')
        logging_messages = 0
        logging_service = new Service('test.logging',
          service_fn: (req) ->
            console.log req
            logging_messages += 1
        )

        resource = new Resource(
          "testResource", "testResource",
          logging_endpoint: 'test.logging'
        )

        resource.check_privilages = -> true
        resource.show = (payload) -> return {body: {"hello": "world"}}

        bb.all([logging_service.start(), service.start(), resource.start()])
        .then( ->
          service.sendMessage('testResource', {verb: "GET", body: "1"})
          .delay(10)
        )
        .spread((resp, body) ->
          console.log logging_messages
          expect(logging_messages).to.equal(2)
        )
        .finally(->
          bb.all([logging_service.stop(), service.stop(), resource.stop()])
        )

      it 'should be able to add additional logging data to the logged events', ->
        service = new Service('testService')
        log_message = null
        logging_service = new Service('test.logging',
          service_fn: (req) ->
            log_message = req.data.response.log
        )
        resource = new Resource(
          "testResource", "testResource",
          logging_endpoint: 'test.logging'
        )

        resource.check_privilages = -> true
        resource.show = (payload) ->
          return {
            body: { "hello": "world" }
            log:  { message: "log message" }
          }

        bb.all([logging_service.start(), service.start(), resource.start()])
        .then( ->
          service.sendMessage('testResource', {verb: "GET", body: "2"})
          .delay(10)
        )
        .spread((resp, body) ->
          expect(log_message.message).to.equal "log message"
        )
        .finally(->
          bb.all([logging_service.stop(), service.stop(), resource.stop()])
        )

  describe 'unhappy', ->
    describe 'platfrom.error', ->
      it "unauthenticated", ->
        service = new Service('testService')
        resource = new Resource("testResource")
        resource.check_privilages = -> false

        bb.all([service.start(), resource.start()])
        .then( ->
          service.sendMessage('testResource', {verb: "GET"})
        )
        .spread((resp, body) ->
          expect(body.status_code).to.equal 403
        )
        .finally(->
          bb.all([service.stop(), resource.stop()])
        )


    describe 'service.error', ->
      it "should return 405 if not implemented method", ->
        service = new Service('testService')
        resource = new Resource("testResource")
        resource.check_privilages = -> true

        bb.all([service.start(), resource.start()])
        .then( ->
          service.sendMessage('testResource', {verb: "GET"})
        )
        .spread((resp, body) ->
          expect(body.status_code).to.equal 405
        )
        .finally(->
          bb.all([service.stop(), resource.stop()])
        )
