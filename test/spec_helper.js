process.env.NODE_ENV = 'test';

// Require test packages
const chai = require('chai');

global._ = require('lodash');

// Require packages
global.bb = require('bluebird');
bb.config({ longStackTraces: true });
bb.onPossiblyUnhandledRejection(() => {});
bb.onUnhandledRejectionHandled(() => {});

global.msgpack = require('msgpack');

global.expect = chai.expect;
global.assert = chai.assert;

// Local files
global.Service = require('../src/alchemy-ether');

global.random_name = (prefix) => {
return `${prefix}_${_.random(0, 99999999)}`;
};

global.random_service = () => {
return random_name('random_service');
};
