
process.env.NODE_ENV = 'test'

#Require test packages
chai = require 'chai'

global._ = require 'lodash'

#require packages
global.bb = require 'bluebird'
bb.longStackTraces()

bb.onUnhandledRejectionHandled( -> )
bb.onPossiblyUnhandledRejection( -> )

global.msgpack = require('msgpack')


global.expect = chai.expect;
global.assert = chai.assert;


#local files
AlchemyEther = require("../src/alchemy-ether")
global.Service = AlchemyEther.Service
global.ServiceConnectionManager = AlchemyEther.ServiceConnectionManager


global.random_name = (prefix) ->
  "#{prefix}_#{_.random(0, 99999999)}"

global.random_service = ->
  random_name("random_service")
