
package flux.channel;

using flux.Core;
import flux.Session;
import flux.Channel;
import flux.channel.Flow;


class ClientSinkImpl extends SinkImpl {

  public function new() {
    super();
    _myfill = myfill;
  }

  function
  myfill(pkt:Pkt<Dynamic>,chan:String,?meta:Dynamic) {
    _conduit.pump("dummy",pkt,chan,meta);
    //notify(Outgoing("dummy",pkt,chan,meta));
  }

  override function
  removeChan<T>(pipe:Chan<T>) {
    super.removeChan(pipe);
    reqUnsub("dummy",pipe,function(cb) {
        Core.info("ok unsubbed:"+pipe.pid());
      });
  }

  override function
  reqUnsub(sessId,pipe:Chan<Dynamic>,cb:Either<String,String>->Void) {
    _conduit.leave(pipe.pid()).deliver(cb);
  }
}