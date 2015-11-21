# Alchemy Ether

## Alchemy Micro-services Framework

The Alchemy [Micro-services](http://martinfowler.com/articles/microservices.html) Framework is a framework for creating many small interconnected services that communicate over the RabbitMQ message brokering service. Building services with Alchemy has many benefits, like:

* **High Availability**: being able to run multiple services across many different machines, communicating to a High Availability RabbitMQ Cluster.
* **Smart Load Balancing**: running multiple instances of the same service, will distribute messages to services based on the service capacity and not via a simple round robin approach.
* **Service Discovery** Using RabbitMQ's routing of messages means services can communicate without knowing where they are located.
* **Deployment** you can stop a service, then start a new service without missing any messages because they are buffered on RabbitMQ. Alternatively, you can run multiple versions of the same service concurrently to do rolling deploys.
* **Error Recovery** If a service unexpectedly dies while processing a message, the message can be reprocessed by another service.
* **Polyglot Architecture**: Each service can be implemented in the language that best suites its domain.

## How Alchemy Services Work

An Alchemy service communicates by registering two queues, a **service queue** (shared amongst all instances of a service) and a **response queue** (unique to that service instance). *For the purpose of clarity I will note a service with letters e.g. `A`, `B` and service instances with numbers, e.g. `A1` is service `A` instance `1`.*

A service sends a message to another service by putting a message on its **service queue** (this message includes the **response queue** of the sender). An instance of that service will consume and process the message then respond to the received **response queue**. For example, if service `A1` wanted to message service `B`:

```

|----------|                                                  |------------|
| RabbitMQ | <-- 1. Send message on queue B   --------------- | Service A1 |
|          |                                                  |            |
|          | --- 2. Consume Message from B  -> |------------| |            |
|          |                                   | Service B1 | |            |
|          | <-- 3. Respond on queue A1     -- |------------| |            |
|          |                                                  |            |
|----------| --- 4. Receive response on A1  ----------------> |------------|
```

Passing messages between services this way means that service `A1` can send messages to `B` without knowing which instance of `B` will process the message. If service `B1` becomes overloaded we can see the queue build up messages, and then start a new instance of service `B`, which, with zero configuration changes, immediately start processing messages.

If the instance of `B` dies while processing a message, RabbitMQ will put the message back on the queue which can then be processed by another instance. This happens without the calling service knowing and so this makes the system much more resilient to errors. However, this also means that messages may be processed more than once, so implementing **idempotent** micro-services is very important.

## Alchemy-Ether

Alchemy-Ether is the Node.js implementation of the Alchemy Framework. Node.js is a great environment for Alchemy as its event driven architecture reflects the Alchemy style of communication.

Ether is implemented using [Promises A+](https://promisesaplus.com/) from the [bluebird](http://bluebirdjs.com/docs/getting-started.html) package and implemented in [CoffeeScript](http://coffeescript.org/).

To install Alchemy-Ether:

```
npm install alchemy-ether
```

To create the above described example:

```
Promise = require('bluebird')
Service = require('./src/alchemy-ether').Service

serviceA1 = new Service("A")

serviceB1 = new Service("B", {service_fn: (message) -> console.log message; {"hello"} })

Promise.all([ serviceA1.start(), serviceB1.start() ])
.then( ->
serviceA1.sendMessageToService('B', {'bob'}).then( (resp) -> console.log resp)
)
.then( (resp) ->
  console.log resp
)
.finally( ->
  Promise.all([ serviceA1.stop(), serviceB1.stop()])
)
```



## Documentation

This documentation Alchemy-Ether documentation is generated from its annotated source code, so all aspects of the implementation are covered.

This is the service logger is [Service](./src/service.html)

    Service = require('./service')

This is the service logger is [ServiceConnectionManager](./src/service_connection_manager.html)

    ServiceConnectionManager = require('./service_connection_manager')


    module.exports = {
      Service:                    Service
      ServiceConnectionManager:   ServiceConnectionManager
    }
