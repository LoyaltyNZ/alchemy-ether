describe "Resource", ->
  describe "start stop", ->
    it 'should work', ->
      resource = new Resource("testResource", '/v1/test_resource')
      resource_service = new ResourceService('testResource', [resource])
      resource_service.start()      
      .then(->
        resource_service.stop()
      )


  describe "show", ->
    it 'should work', ->
      resource_name = random_resource()
      resource_path = "/v1/#{resource_name}"
      resource = new Resource(resource_name, resource_path)

      resource.show = (payload) ->
        return { body: {"hello": "world"} }
      resource.show.public = true

      service_name = random_service()
      resource_service = new ResourceService(service_name, [resource])

      service = new Service('testService')
      bb.all([service.start(), resource_service.start()])
      .then( ->
        service.sendMessageToService(service_name, {verb: "GET", path: resource_path})
      )
      .spread((resp, body) ->
        expect(body.body.hello).to.equal "world"
        expect(body.status_code).to.equal 200
      )
      .then( ->
        service.sendMessageToResource({verb: "GET", path: resource_path})
      )
      .spread((resp, body) ->
        expect(body.body.hello).to.equal "world"
        expect(body.status_code).to.equal 200
      )
      .finally(->
        bb.all([service.stop(), resource_service.stop()])
      )

    it 'should route to the right resource', ->
      resource1_name = random_resource()
      resource1_path = "/v1/#{resource1_name}"
      resource1 = new Resource(resource1_name, resource1_path)
      resource1.show = (payload) ->
        return { body: {"iam": "resource1"} }
      resource1.show.public = true

      resource2_name = random_resource()
      resource2_path = "/v1/#{resource2_name}"
      resource2 = new Resource(resource2_name, resource2_path)
      resource2.show = (payload) ->
        return { body: {"iam": "resource2"} }
      resource2.show.public = true

      service_name = random_service()
      resource_service = new ResourceService(service_name, [resource1, resource2])

      service = new Service('testService')
      bb.all([service.start(), resource_service.start()])
      .then( ->
        req1 = service.sendMessageToResource({verb: "GET", path: resource1_path})
        req2 = service.sendMessageToResource({verb: "GET", path: resource2_path})
        req3 = service.sendMessageToResource({verb: "GET", path: "#{resource1_path}/"})
        req4 = service.sendMessageToResource({verb: "GET", path: "#{resource1_path}/identifier"})
        req5 = service.sendMessageToResource({verb: "GET", path: "#{resource1_path}/identifier/ksecond"})
        
        bb.all([req1, req2, req3, req4, req5])
      )
      .then((resps) ->
        [resp1, resp2, resp3, resp4, resp5 ] = resps.map( (x) -> x[1])
        expect(resp1.body.iam).to.equal "resource1"
        expect(resp1.status_code).to.equal 200

        expect(resp2.body.iam).to.equal "resource2"
        expect(resp2.status_code).to.equal 200

        expect(resp3.body.iam).to.equal "resource1"
        expect(resp3.status_code).to.equal 200

        expect(resp4.body.iam).to.equal "resource1"
        expect(resp4.status_code).to.equal 200

        expect(resp5.body.iam).to.equal "resource1"
        expect(resp5.status_code).to.equal 200
      )
      .finally(->
        bb.all([service.stop(), resource_service.stop()])
      )

    it 'should route to the resources at different levels', ->
      resource1_name = random_resource()
      resource1_path = "/#{resource1_name}"
      resource1 = new Resource(resource1_name, resource1_path)
      resource1.show = (payload) ->
        return { body: {"iam": "level_1"} }
      resource1.show.public = true

      resource2_path = "/v1/#{resource1_name}"
      resource2 = new Resource(random_resource(), resource2_path)
      resource2.show = (payload) ->
        return { body: {"iam": "level_2"} }
      resource2.show.public = true

      service_name = random_service()
      resource_service = new ResourceService(service_name, [resource1, resource2])

      service = new Service('testService')
      bb.all([service.start(), resource_service.start()])
      .then( ->
        req1 = service.sendMessageToResource({verb: "GET", path: resource1_path})
        req2 = service.sendMessageToResource({verb: "GET", path: resource2_path})

        bb.all([req1, req2])
      )
      .then((resps) ->
        [resp1, resp2 ] = resps.map( (x) -> x[1])
        expect(resp1.body.iam).to.equal "level_1"
        expect(resp1.status_code).to.equal 200

        expect(resp2.body.iam).to.equal "level_2"
        expect(resp2.status_code).to.equal 200
      )
      .finally(->
        bb.all([service.stop(), resource_service.stop()])
      )


    it 'should throw error if sending to resource that is not there', ->
      resource1_name = random_resource()
      resource1_path = "/v1/#{resource1_name}"
      resource1 = new Resource(resource1_name, resource1_path)
      resource1.show = (payload) ->
        return { body: {"iam": "resource1"} }
      resource1.show.public = true

      service_name = random_service()
      resource_service = new ResourceService(service_name, [resource1])

      service = new Service('testService')
      bb.all([service.start(), resource_service.start()])
      .then( ->
        badreq1 = service.sendMessageToResource({verb: "GET", path: "#{resource1_name}"})
        .then( ->
          throw "SHOULD NOT GET HERE"
        )
        .catch(Service.MessageNotDeliveredError, (err) ->

        )

        badreq2 = service.sendMessageToResource({verb: "GET", path: "/v2/#{resource1_name}"})
        .then( ->
          throw "SHOULD NOT GET HERE"
        )
        .catch(Service.MessageNotDeliveredError, (err) ->
        )
        
        badreq3 = service.sendMessageToResource({verb: "GET", path: "/prefix#{resource1_path}"})
        .then( ->
          throw "SHOULD NOT GET HERE"
        )
        .catch(Service.MessageNotDeliveredError, (err) ->
        )

        badreq4 = service.sendMessageToResource({verb: "GET", path: "/v1/"})
        .then( ->
          throw "SHOULD NOT GET HERE"
        )
        .catch(Service.MessageNotDeliveredError, (err) ->
        )

        bb.all([badreq1, badreq2, badreq3, badreq4])

      )
      .finally(->
        bb.all([service.stop(), resource_service.stop()])
      )


    describe "logging", ->

      it 'should log 2 (inbound and outbound) messages', ->
        service = new Service('testService')
        logging_messages = 0
        logging_service = new Service('test.logging', 
          service_fn: (req) -> 
            logging_messages += 1
        )

        resource = new Resource(
          "resource"
          "/v1/test_resource"
        )

        resource.show = (payload) -> return {body: {"hello": "world"}}
        resource.show.public = true
        resource_service = new ResourceService('testResource', [resource], logging_endpoint: 'test.logging')

        bb.all([logging_service.start(), service.start(), resource_service.start()])
        .then( ->
          service.sendMessageToResource({verb: "GET", path: "/v1/test_resource"})
          .delay(20)
        )
        .spread((resp, body) ->
          expect(logging_messages).to.equal(2)
        )
        .finally(->
          bb.all([logging_service.stop(), service.stop(), resource_service.stop()])
        )

      it 'should be able to add additional logging data to the logged events', ->
        service = new Service('testService')
        log_message = null
        logging_service = new Service('test.logging', 
          service_fn: (req) ->
            log_message = req.data.response.log
        )


        resource = new Resource(
          "resource"
          "/v1/test_resource"
        )

        resource.show = (payload) -> 
          return {
            body: { "hello": "world" }
            log:  { message: "log message" }
          }
        resource.show.public = true
        resource_service = new ResourceService('testResource', [resource], logging_endpoint: 'test.logging')



        bb.all([logging_service.start(), service.start(), resource_service.start()])
        .then( ->
          service.sendMessageToResource({verb: "GET", path: "/v1/test_resource"})
          .delay(10)
        )
        .spread((resp, body) ->
          log_message
        )
        .finally(->
          bb.all([logging_service.stop(), service.stop(), resource_service.stop()])
        )

  describe 'unhappy', ->
    describe 'platfrom.error', ->
      it "unauthenticated", ->
        service = new Service('testService')
        resource = new Resource("test_resource", '/v1/test_resource')
        
        resource.show.public = false
        resource_service = new ResourceService('testResource', [resource])
        resource_service.check_privilages = -> false


        bb.all([service.start(), resource_service.start()])
        .then( ->
          service.sendMessageToResource({verb: "GET", path: "/v1/test_resource"})
        )
        .spread((resp, body) ->
          expect(body.status_code).to.equal 403
        )
        .finally(->
          bb.all([service.stop(), resource_service.stop()])
        ) 


    describe 'service.error', ->
      it "should return 405 if not implemented method", ->
        service = new Service('testService')
        resource = new Resource("test_resource", '/v1/test_resource')
        resource.show.public = true
        resource_service = new ResourceService('testResource', [resource])

        bb.all([service.start(), resource_service.start()])
        .then( ->
          service.sendMessageToResource({verb: "GET", path: "/v1/test_resource"})
        )
        .spread((resp, body) ->
          expect(body.status_code).to.equal 405
        )
        .finally(->
          bb.all([service.stop(), resource_service.stop()])
        )
