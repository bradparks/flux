/*

  hxc: -D nodejs
 */

package flux.http;

using  flux.Core;
import flux.Http;
import flux.http.Mime;

import js.Node;

private typedef Cache = {
    var mtime:Float;
    var buf:NodeBuffer;
}

class HttpImpl
extends flux.core.ObservableImpl<HttpEvents>,
implements HttpServer
  {
//implements Part<HostPort,String,HttpServer,HttpEvents> {
  
//  public var part_:Part_<HostPort,String,HttpServer,HttpEvents>;
  
  var _cache:Hash<Cache>;
  var _getHandler:String->NodeHttpServerReq->NodeHttpServerResp->Int->Void;
  var _routes:Array<{re:EReg,handler:THandler}>;
  var _notFound:NodeHttpServerReq->NodeHttpServerResp->Void;
  var _creds:NodeCredDetails;
  
  var _index = "/index.html";
  var _root:String = null;
  var _serverName:String;
 
  static var readStreamOpt:ReadStreamOpt = cast {
        flags: 'r',
        mode: 0666
  };
  
  static var _formidable:Dynamic ;

  static function __init__() {
    _formidable = js.Node.require('formidable');
  }
  
  public function
  new() {
    super();
    _routes = [];

    _index = "/index.html";
    _root = null;
    _serverName = "Flux "+Core.VER;
    
    _getHandler = defaultGetHandler;
    _cache = new Hash();
    
    //part_ = Core.part(this);

  }

  public function
  start_(d:HostPort,oc:Outcome<String,HttpServer>) {
    var server =
      if (_creds != null) 
        Node.https.createServer(_creds,requestHandler);
      else
        Node.http.createServer(requestHandler);

    server.listen(d.port,d.host,function() {
        /*
        stop_(function(d) {
            var p = Core.outcome();
            server.close();
            //_server.on("close",function() {
            p.resolve(Right(cast this));
            //  });
            return p;
          });
        */

        if (_creds != null)
          Core.info("Listening on Https "+_serverName+" on "+d.host+":"+d.port);
        else
          Core.info("Listening on Http "+_serverName+" on "+d.host+":"+d.port);
        
        oc.resolve(Right(cast(this,HttpServer)));
      });
    
    return oc;
  }

  function
  requestHandler(req:NodeHttpServerReq,resp:NodeHttpServerResp) {
      var
        url = req.url,
        match = false;

      if (_routes != null) {
        for (r in _routes) {
          if (r.re.match(url)) {
            match = true;
            try {
              r.handler(r.re,req,resp);
            } catch(ex:Dynamic) {
              Core.error("handler exp:"+ex);
            }
            
            break;
          }
        }
      }
        
      if (!match && _root != null) {
        if (req.method == "GET") {
          if (url == "/") url = _index;
          _getHandler(url,req,resp,200);
        }
      }
  }
 

  public function
  handler(r:EReg,handler:THandler):HttpServer {
    _routes.push({re:r,handler:handler});
    return this;
  }

  public function
  notFound(nf:NodeHttpServerReq->NodeHttpServerResp->Void):HttpServer {
    _notFound = nf;
    return this;
  }

  public function
  index(indexFile:String):HttpServer {
    _index = indexFile;
    return this;
  }
  
  public function
  serverName(serverName:String):HttpServer {
    _serverName = serverName;
    return this;
  }
  
  public function
  root(rootDir:String):HttpServer {
    _root = if (!rootDir.endsWith("/")) rootDir else rootDir.substr(0,-1);
    _getHandler = serve;
    return this;
  }

  public function
  credentials(key:String,cert:String,?ca:Array<String>):HttpServer {
    var k = Node.fs.readFileSync(key);
    var c = Node.fs.readFileSync(cert);
    _creds = {key:k, cert:c,ca:ca};
    return this;
  }
  
  function
  defaultGetHandler(path:String,req:NodeHttpServerReq,resp:NodeHttpServerResp,statusCode:Int) {
    do404(req,resp);
  }

  public function
  fields(req:NodeHttpServerReq,cb:TFields,uploadDir="/tmp") {
    parseFields(req,cb,uploadDir);
  }

  public static function
  parseFields(req:NodeHttpServerReq,cb:TFields,?uploadDir:String) {
      var
        form:Dynamic = untyped __js__('new flux.http.HttpImpl._formidable.IncomingForm()'),
        fields = new Hash<String>(),
        files:Array<{field:String,file:TUploadFile}> = null;

      if (uploadDir != null) form.uploadDir = uploadDir;
      
      form.on('field',function(field,value) {
          fields.set(Std.string(field),Std.string(value));
        })
        .on('file',function(field,file) {
            if (files == null) files = [];
            files.push({field:field,file:file});
          })
        .on('end', function() {
            cb(fields,files);
          });
      form.parse(req);
  }

  public function
  serve(path:String,req:NodeHttpServerReq,resp:NodeHttpServerResp,statusCode=200) {

    var fileToServe = if (_root != null ) _root+path else path;

    trace("serving: "+path);

    Node.fs.stat(fileToServe,function (e, stat:NodeStat) {
        if (e != null) {
          do404(req,resp);
          return;
        }

        if (stat.isFile()) {
          trace("stat.mtime = "+stat.mtime.toDateString());
          
          var
            mtimeObj = stat.mtime,
            fmtime = mtimeObj.toDateString(),
            size = stat.size,
            eTag = Node.stringify([stat.ino, size, fmtime].join('-'));

          
            //          since = Reflect.field(req.headers,"if-modified-since"),
            //            modified = false;
          
          /*
            if (since != null) {
            modified = (parse(since) < fmtime) ;
            }*/
          
          if (Reflect.field(req.headers,"if-none-match") == eTag ){
            resp.statusCode = 304;
            headers(resp,size,path,eTag,mtimeObj);
            resp.end();
            return;
          }

          resp.statusCode = statusCode;
          headers(resp,size,path,eTag,mtimeObj);
          serveFromCache(resp,fileToServe,stat,mtimeObj.getTime());
          
        } else if (stat.isDirectory()) {
          do404(req,resp);
        } else {
          do404(req,resp);
        }
      });
  }

  public function
  serveNoCache(path:String,req:NodeHttpServerReq,resp:NodeHttpServerResp,statusCode=200) {
    var fileToServe = if (_root != null ) _root+path else path;
    Node.fs.stat(fileToServe,function (e, stat:NodeStat) {
        if (e != null) {
          do404(req,resp);
          return;
        }

        var
          mtime = stat.mtime,
          size = stat.size;

          if (stat.isFile()) {
            resp.statusCode = statusCode;
            headers(resp,size,path,null,mtime);
            resp.setHeader("cache-control","no-cache");
            Node.fs.createReadStream(path,readStreamOpt).pipe(resp);
        } else if (stat.isDirectory()) {
          do404(req,resp);
        } else {
          do404(req,resp);
        }
      });
  }
                 
  function do404(req:NodeHttpServerReq,resp:NodeHttpServerResp) {
    //    resp.writeHead(404);
    if (_notFound != null)
      _notFound(req,resp);
    //resp.end();
  }

  function headers(resp:NodeHttpServerResp,size,path,etag,mtime:NodeJsDate) {
    resp.setHeader("Content-Length",size);
    resp.setHeader("Content-Type",Reflect.field(Mime.types,Node.path.extname(path).substr(1)));
    var d:NodeJsDate = untyped __js__("new Date(Date.now())");
    resp.setHeader("Date",d.toUTCString());
    if (etag != null)
      resp.setHeader("ETag",etag);
    resp.setHeader("Last-Modified", mtime.toUTCString());
    resp.setHeader("Server",_serverName);
  }

  function
  serveFromCache(resp:NodeHttpServerResp,path:String,stat:NodeStat,mtime:Int) {
    var cached = _cache.get(path) ;
    if (cached == null) {
      pipeFile(resp,path,stat,mtime);
    } else {
      if (cached.mtime < mtime) {
        pipeFile(resp,path,stat,mtime);
      } else {
        //        resp.end(cached.buf.toString(NodeC.ASCII));
        resp.end(cached.buf.toString(NodeC.BINARY));
      }
    }    
  }

  function
  pipeFile(resp:NodeHttpServerResp,path:String,stat:NodeStat,mtime:Int){
    var
      buf = new NodeBuffer(stat.size),
      offset = 0;
      _cache.set(path,{mtime:mtime,buf:buf});
      
      Node.fs.createReadStream(path,readStreamOpt)
        .on('error', function (err) {
          Node.console.error(err);
          })
        .on('data', function (chunk) {
            chunk.copy(buf, offset);
            offset += chunk.length;
          })
        .on('close', function () {

          })
        .pipe(resp);
  } 

  static function
  UTCString(d:Date) : String {
    return untyped __js__("d.toUTCString()");
    }

  static function
  parse(d:String):Float {
    return untyped __js__("Date.parse(d)");
  }
}