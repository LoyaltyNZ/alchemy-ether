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
          console.log body
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
          console.log body
          expect(body.status_code).to.equal 405
        )
        .finally(->
          bb.all([service.stop(), resource.stop()])
        )
