# Read-only. Queue depth here is what the rabbitmq-autoscale kit feature
# scales on, and nothing in the previous example apps exposed it.
#
# These three are NOT aliases of /management/*, which comes from the
# generic protocol-prefixed loop and answers differently: /management/queues
# returns plain-text names with no depth, and GET /management/queue/:name
# is 501, since the management adapter has no consume. Both surfaces are
# intentional and neither redirects to the other; the README documents the
# divergence in full.
get '/mgmt/ping' do
  content_type :json
  status 200
  body JSON.pretty_generate(management.overview)
end

get '/mgmt/queues' do
  content_type :json
  status 200
  body JSON.pretty_generate(management.queues)
end

get '/mgmt/queue/:name' do
  queue = management.queue(params[:name])
  halt 404, 'NO-SUCH-QUEUE' if queue.nil?

  content_type :json
  status 200
  body JSON.pretty_generate(queue)
end
