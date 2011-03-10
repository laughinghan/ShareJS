io = require 'socket.io'
util = require 'util'

model = require './model'
events = require './events'

p = util.debug
i = util.inspect
p = ->
i = ->

exports.install = (server = require('./frontend').server) ->
	socket = io.listen server, {log:null}

	socket.on 'connection', (client) ->
		p "New client connected from #{client.request.socket.remoteAddress} with sessionId #{client.sessionId}"

		lastSentDoc = null
		lastReceivedDoc = null
		docState = {} # Map from docName -> {listener:fn, queue:[msg], busy:bool}

		send = (msg) ->
			p "Sending #{i msg}"
			# msg _must_ have the docname set. We'll remove it if its the same as lastReceivedDoc.
			delete msg.doc if msg.doc == lastSentDoc
			lastSentDoc = msg.doc
			client.send msg

		# Attempt to follow a document with a given name. Version is optional.
		follow = (data, callback) ->
			docName = data.doc
			version = data.v
			throw new Error 'Doc already followed' if docState[docName].listener?
			p "Registering follower on #{docName} by #{client.sessionId} at #{version}"

			sendOpenConfirmation = (v) ->
				p "Following #{docName} at #{v} by #{client.sessionId}"
				send {doc:docName, follow:true, v:v}
				callback()

			docState[docName].listener = listener = (opData) ->
				p "follow listener doc:#{docName} opdata:#{i opData} v:#{version}"

				# Skip the op if this client sent it.
				return if opData.meta?.source == client.sessionId != undefined

				opMsg =
					op: opData.op
					v: opData.v

				send opMsg
			
			if version?
				# Tell the client the doc is open at the requested version
				sendOpenConfirmation(version)
				events.listenFromVersion docName, version, listener
			else
				# If the version is blank, we'll open the doc at the most recent version
				events.listen docName, sendOpenConfirmation, listener

		# The client unfollows a document
		unfollow = (data, callback) ->
			p "Closing #{data.doc}"
			listener = docState[data.doc].listener
			throw new Error 'Doc already closed' unless listener?

			events.removeListener data.doc, listener
			docState[data.doc].listener = null
			send {doc:data.doc, follow:false}
			callback()

		# We received an op from the client
		opReceived = (data, callback) ->
			throw new Error 'No docName specified' unless data.doc?
			throw new Error 'No version specified' unless data.v?

			op_data = {v:data.v, op:data.op, meta:{source:client.sessionId}}
			model.applyOp data.doc, op_data, (error, appliedVersion) ->
				msg = if error?
					p "Sending error to client: #{error.message}, #{error.stack}"
					{doc:data.doc, v:null, error: error.message}
				else
					{doc:data.doc, v:appliedVersion}

				send msg
				callback()

		# The client requested a document snapshot
		snapshotRequest = (data, callback) ->
			throw new Error 'Snapshot request at version not currently implemented' if data.v?
			throw new Error 'No docName specified' unless data.doc?

			model.getSnapshot data.doc, (doc) ->
				msg = {doc:data.doc, v:doc.v, type:doc.type?.name || null, snapshot:doc.snapshot}
				send msg
				callback()

		flush = (state) ->
			p "flush state #{i state}"
			p '1: ' + (i docState)
			return if state.busy || state.queue.length == 0
			state.busy = true

			data = state.queue.shift()

			callback = ->
				p 'flush complete...'
				state.busy = false
				p '2: ' + (i docState)
				flush state

			p "processing data #{i data}"
			try
				if data.follow? # Opening a document.
					if data.follow
						follow data, callback
					else
						unfollow data, callback

				else if data.op? # The client is applying an op.
					opReceived data, callback

				else if data.snapshot != undefined # Snapshot request.
					snapshotRequest data, callback

				else
					p "Unknown message received: #{util.inspect data}"

			catch error
				util.debug error.stack
				# ... And disconnect the client?
				callback()

		# And now the actual message handler.
		client.on 'message', (data) ->
			p 'message ' + i data

			try
				data = JSON.parse data if typeof(data) == 'string'

				if data.doc?
					lastReceivedDoc = data.doc
				else
					throw new Error 'msg.doc missing' unless lastReceivedDoc
					data.doc = lastReceivedDoc
			catch error
				util.debug error.stack
				return

			p '3: ' + (i docState)
			docState[data.doc] ||= {listener:null, queue:[], busy:no}
			docState[data.doc].queue.push data
			p '4: ' + (i docState)
			flush docState[data.doc]

		client.on 'disconnect', ->
			p "client #{client.sessionId} disconnected"
			for docName, state of docState
				state.busy = true
				state.queue = []
				events.removeListener docName, state.listener if state.listener?

			docState = null
