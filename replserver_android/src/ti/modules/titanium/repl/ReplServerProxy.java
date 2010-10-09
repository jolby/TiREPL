package ti.modules.titanium.repl;

import org.appcelerator.titanium.TiBlob;
import org.appcelerator.titanium.TiContext;
import org.appcelerator.titanium.TiDict;
import org.appcelerator.titanium.TiProxy;
import org.appcelerator.titanium.util.Log;


public class ReplServerProxy extends TiProxy {

    private ReplServer replServer;

    public ReplServerProxy(TiContext context) {
        super(context);            
        this.replServer = new ReplServer(this);
    }

    public void start() {
        replServer.start();
    }

    public void stop() {
        replServer.stop();
    }
    
    public int getListenPort() {
        return replServer.getListenPort();
    }

    public void setListenPort(int port) {
        replServer.setListenPort(port);
    }

    public boolean isRunning() {
        return replServer.isRunning();
    }
    
    public String status() {
        return replServer.status();
    }
}