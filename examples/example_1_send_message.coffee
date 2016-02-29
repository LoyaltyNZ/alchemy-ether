# # Example 1: Sending a message to a service
#
# Prerequisites:
# * RabbitMQ running

Service = require '../src/alchemy-ether'

serviceA1 = new Service("A")

serviceB1 = new Service("B", {
  # Service B's processing function
  service_fn: (message) ->
    { body: "Hello #{message.body}" }
})

# Start the Services
serviceA1.start().then( -> serviceB1.start())
.then( ->
  # Service A1 sending message to B
  serviceA1.send_request_to_service('B', {body: 'Alice'})
)
.then( (response) ->
  console.log(response.body) # "Hello Alice"
)
.finally( ->
  serviceA1.stop().then( -> serviceB1.stop())
)
