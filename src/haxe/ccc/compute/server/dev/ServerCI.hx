package ccc.compute.server.dev;

/**
 * Development server:
 * 1) Starts up a local dev stack if needed
 * 2) Detects new server code
 * 3) Reloads all CCC stacks with the new server
 * 4) Runs the server functional tests on all servers
 * 5) Hides stderr/out, but shows errors
 */

import haxe.Json;
import haxe.remoting.JsonRpc;

import ccc.compute.client.ClientTools;
import ccc.compute.client.cli.CliTools;

import js.Node;
import js.node.Buffer;
import js.node.Fs;
import js.node.Path;
import js.node.child_process.ChildProcess;
import js.node.ChildProcess;
import js.node.http.*;
import js.node.Http;
import js.node.Url;
import js.node.events.EventEmitter;
import js.node.stream.Readable;
import js.npm.commander.Commander;
import js.npm.clicolor.CliColor;

import promhx.RequestPromises;
import promhx.RetryPromise;
import promhx.deferred.DeferredPromise;

using promhx.PromiseTools;

class ServerCI
{
	static function main()
	{
		//Required for source mapping
		js.npm.sourcemapsupport.SourceMapSupport;
		//Embed various files
		ErrorToJson;
		runServer();
	}

	static function getLocalDockerStackHost() :Host
	{
		try {
			var hostname = ConnectionToolsDocker.getDockerHost();
			return new Host(hostname, new Port(SERVER_DEFAULT_PORT));
		} catch(err :Dynamic) {
			trace('err=${err}');
			return null;
		}
	}

	static function runLocalDevStack() :Promise<Bool>
	{
		var process = ChildProcess.spawn('./bin/run-stack-local-dev');

		function traceOut(data :js.node.Buffer) {
			if (data != null) {
				var s = data.toString('utf8');
				s = s.substr(0, s.length - 1);
				trace(s);
			}
		}

		process.stdout.addListener(ReadableEvent.Data, traceOut);
		process.stderr.addListener(ReadableEvent.Data, traceOut);

		var promise = new DeferredPromise();
		process.once(ChildProcessEvent.Exit, function(code, signal) {
			trace('Stack exited with code=$code');
			if (!(promise.boundPromise.isRejected() || promise.boundPromise.isResolved() || promise.boundPromise.isErrored())) {
				promise.boundPromise.reject('code=$code signal=$signal');
			}
		});

		var host = getLocalDockerStackHost();

		return Promise.promise(true)
			.pipe(function(_) {
				//Give a decent amount of time to build and start the stack
				//This may include downlowding large images
				var maxAttempts = 60 * 5;
				var delayMilliseconds = 1000;
				return ClientTools.waitUntilServerReady(host, maxAttempts, delayMilliseconds);
			})
			// .pipe(function(_) {
			// 	trace("Server listening! Waiting until ready...");
			// 	return ClientTools.isServerReady(host);
			// })
			.pipe(function(_) {
				process.stdout.removeListener(ReadableEvent.Data, traceOut);
				process.stderr.removeListener(ReadableEvent.Data, traceOut);
				promise.resolve(true);
				trace("Server ready!");
				return promise.boundPromise;
			});
	}

	static function runServer()
	{
		Logger.log = new AbstractLogger({name: 'CI server'});

		var program :Commander = Node.require('commander');

		program
			.version(Json.parse(Fs.readFileSync('package.json', 'utf8')).version)
			.option('-s, --server [address]',
				'Host address to push new builds (e.g. 192.168.50.1:9001)',
				function collect(val :HostName, memo :Array<HostName>) {
					var hostName :HostName = val;
					hostName = CliTools.getHostCheckSshConfig(hostName);
					// var host = new Host(hostName, new Port(SERVER_DEFAULT_PORT));
					memo.push(hostName);
					return memo;
				}, [])
			.option('-l, --local', 'Ensure a local stack running in the local docker daemon')
			.parse(Node.process.argv);

		// untyped program. local = true;
		Promise.promise(true)
			.pipe(function(_) {
				if (untyped program.local == true) {
					var localhost = getLocalDockerStackHost();
					if (localhost != null) {
						trace('Check for running local stack...');
						return ClientTools.isServerListening(localhost)
							.pipe(function(isListening) {
								if (isListening) {
									trace('Existing stack listening on $localhost');
									return Promise.promise([localhost.getHostname()]);
								} else {
									trace('No existing local stack, booting up...');
									return runLocalDevStack()
										.then(function(_) {
											trace('New stack ready!');
											return [localhost.getHostname()];
										});
								}
							});
					} else {
						trace('No local docker daemon, cannot start local stack');
						return Promise.promise([]);
					}
				} else {
					return Promise.promise([]);
				}
			})
			.then(function(servers) {
				servers = servers.concat(untyped program.server);
				startFileWatcher(servers);
			});
	}

	static function startFileWatcher(servers :Array<HostName>)
	{
		var serverFilePath = 'build/$APP_SERVER_FILE';
		var watchPaths = [
			serverFilePath,
			'build/test/server-test-runner.js',
		];
		var sizes = new Map<String, Int>();
		watchPaths.iter(function(path) {
			try {
				sizes.set(path, Std.int(Fs.statSync(path).size));
			} catch(err :Dynamic) {
				trace(err);
			}
		});

		// var listenPath = 'build/';
		trace('Listening servers=${servers}');
		trace('Listening to all changes on $watchPaths');

		//Watch for file changes, and automatically reload
		var chokidar :{watch:Array<String>->Dynamic->EventEmitter<Dynamic>} = Node.require('chokidar');
		var watcher = chokidar.watch(watchPaths, {
			// ignored: /[\/\\]\./,
			persistent: true,
			usePolling: true,
			interval: 100,
			binaryInterval: 300,
			alwaysStat: true,
			awaitWriteFinish: true
		});

		var isReloading = false;
		var reloadRequest = false;

		var maybeReload;
		maybeReload = function() {
			if (isReloading) {
				return;
			}
			if (!reloadRequest) {
				return;
			}
			isReloading = true;
			reloadRequest = false;
			var serverCodeString :String = null;
			try {
				serverCodeString = Fs.readFileSync(serverFilePath, 'utf8');
				trace('Reloading and running tests');
				reloadAndRunTests(servers, serverCodeString)
					.then(function(_) {
						return true;
					})
					.errorPipe(function(err) {
						Node.process.stderr.write(CliColor.red(Std.string(err)));
						return Promise.promise(true);
					})
					.then(function(_) {
						isReloading = false;
						maybeReload();
					});
			} catch (err :Dynamic) {
				isReloading = false;
				trace(err);
				maybeReload();
			}
		}

		watcher.on('change', function(path, stats) {
			trace('Got file change path=$path');
			var size = Std.int(stats.size);
			if (sizes.exists(path) && sizes.get(path) == size) {
				trace('File the same size, ignoring');
				return;
			}
			sizes.set(path, size);
			reloadRequest = true;
			maybeReload();
		});

		//Start with the tests
		reloadRequest = true;
		maybeReload();
	}

	static function reloadAndRunTests(hosts :Array<HostName>, serverCode :String) :Promise<Bool>
	{
		return Promise.whenAll(hosts.map(function(hostName) {
			// var hostName :HostName = host.getHostname();
			// hostName = CliTools.getHostCheckSshConfig(hostName);
			var reloadHost = new Host(hostName, new Port(SERVER_RELOADER_PORT));
			var mainHost = new Host(hostName, new Port(SERVER_DEFAULT_PORT));
			return reloadServer(reloadHost, serverCode)
				.pipe(function(_) {
					return runTestsOnHost(mainHost);
				});
		}))
		.thenTrue();
	}

	static function runTestsOnHost(host :Host) :Promise<Bool>
	{
		var url = 'http://${host}${SERVER_RPC_URL}/server-tests';
		return RequestPromises.get(url)
			.then(function(result) {
				trace(result);
				return true;
			})
			.errorPipe(function(err) {
				traceRed(err);
				return Promise.promise(false);
			});
	}

	static function reloadServer(host :Host, serverCode :String) :Promise<Bool>
	{
		var url = 'http://${host}${SERVER_PATH_RELOAD}';
		trace('Reloading server at $url...');
		return RequestPromises.post(url, serverCode)
			.thenWait(1000)
			.pipe(function(_) {
				//Give a decent amount of time to build and start the stack
				//This may include downlowding large images
				var maxAttempts = 60 * 5;
				var delayMilliseconds = 1000;
				var pingHost = new Host(host.getHostname(), new Port(SERVER_DEFAULT_PORT));
				return ClientTools.waitUntilServerReady(pingHost, maxAttempts, delayMilliseconds);
			})
			.then(function(out) {
				trace('Reloaded and ready server ${host} out=$out');
				return true;
			});
	}
}