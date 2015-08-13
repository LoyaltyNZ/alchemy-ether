
#Require test packages
chai = require 'chai'
chaiAsPromised = require("chai-as-promised")
chai.use(chaiAsPromised);

global.sinon = require 'sinon'
global._ = require 'lodash'

#require packages
global.bb = require 'bluebird'
bb.longStackTraces()

bb.onUnhandledRejectionHandled( -> )
bb.onPossiblyUnhandledRejection( -> )

global.qhttp =  require("q-io/http")
global.msgpack = require('msgpack')


global.expect = chai.expect;
global.assert = chai.assert;


#local files
alchemy = require("../src/alchemy")
global.Service = alchemy.Service
global.Resource = alchemy.Resource
global.ResourceService = alchemy.ResourceService
global.SessionClient = alchemy.SessionClient

global.Util = require("../src/util")


global.random_name = (prefix) ->
  "#{prefix}_#{_.random(0, 99999999)}"

global.random_resource = ->
  random_name("resource")

global.random_service = ->
  random_name("random_service")
