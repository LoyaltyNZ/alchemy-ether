create_session_client = ->
  new SessionClient('localhost:11211', 0)

describe 'SessionClient', ->

  describe '#constructor', ->
    it 'should work', ->
      session_client = new SessionClient()

    it 'should set the memcached host', ->
      session_client = new SessionClient("blabla")
      expect(session_client.memcache_host).to.equal("blabla")

  describe '#connect', ->
    it 'should correctly connect', ->
      session_client = create_session_client()
      session_client.connect()

  describe '#disconnect', ->
    it 'should remove memcached from session_clientance', ->
      session_client = create_session_client()
      session_client.connect()
      .then( ->
        expect(session_client.connected()).to.be.true
        session_client.disconnect()
      )
      .then( ->
        expect(session_client.connected()).to.be.false
      )

  describe '#getSession', ->
    it 'should return null for non session information', ->
      session_client = create_session_client()
      session_client.connect()
      .then( ->
        session_client.getSession("non_existant_session")
      )
      .then((session) ->
        expect(session).to.be.null
        session_client.disconnect()
      )

    it 'should return stored session data', ->
      session_client = create_session_client()
      session_client.connect()
      .then( ->
        session_client.setSession("session_id", {hello: "world"})
      )
      .then( ->
        session_client.getSession("session_id")
      )
      .then((session) ->
        expect(session.hello).to.equal("world")
        session_client.disconnect()
      )
