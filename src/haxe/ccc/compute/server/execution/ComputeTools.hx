package ccc.compute.server.execution;


import t9.abstracts.net.*;

class ComputeTools
{
	inline public static function rpcUrl(host :Host) :UrlString
	{
		return new UrlString('http://$host${Constants.SERVER_RPC_URL}');
	}

	inline public static function createUniqueId() :String
	{
#if js
		// return js.npm.shortid.ShortId.generate();
		return co.janicek.core.math.UUID.uuidRfc4122V4();
#else
		#throw 'Not yet supported';
#end
	}
}