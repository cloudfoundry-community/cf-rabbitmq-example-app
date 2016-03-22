# CF RabbitMQ Example App

This app is an example of how you can consume a Cloud Foundry
service within an app.  It can also be used to verify a RabbitMQ
service installation.

It allows you to push message into, and pull messages out of,
RabbitMQ message queues, via a REST endpoint.

### Getting Started

Install the app by pushing it to your Cloud Foundry and binding
with the Pivotal RabbitMQ service

Example:

    $ git clone git@github.com:starkandwayne/cf-rabbitmq-example-app.git
    $ cd rabbitmq-example-app
    $ cf push rabbitmq-example-app --no-start
    $ cf create-service p-rabbitmq development rabbitmq
    $ cf bind-service rabbitmq-example-app rabbitmq

### Endpoints

#### GET /ping

Verifies that the application is up and responding, and can
connect to the RabbitMQ backend service.  Example:

    $ export APP=rabbitmq-example-app.my-cloud-foundry.com
    $ curl $APP/ping
    OK

#### POST /queues

Define a queue, passed in the 'name' field.  Example:

    $ curl -X POST $APP/queues -d 'name=a-test-queue'
    SUCCESS

#### GET /queues

Prints the queues that have been defined so far.  Example:

    $ curl $APP/queues
    a-test-queue

#### PUT /queue/:name

Pushes a message, passed in the 'data' field, into the named
message queue.  Example:

    $ curl -X PUT $APP/queue/a-test-queue -d 'data=Hello'
    SUCCESS


#### GET /queue/:name

Pulls a single message from the named message queue.  Example:

    $ curl -X GET $APP/queue/a-test-queue
    Hello

