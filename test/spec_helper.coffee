
#Require test packages
chai = require 'chai'
chaiAsPromised = require("chai-as-promised")
chai.use(chaiAsPromised);

global.sinon = require 'sinon'


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

global.Util = require("../src/util")


