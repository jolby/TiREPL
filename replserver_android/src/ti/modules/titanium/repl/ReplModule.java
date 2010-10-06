package ti.modules.titanium.repl;
import org.appcelerator.titanium.TiContext;
import org.appcelerator.titanium.TiModule;
import org.appcelerator.titanium.util.Log;


public class ReplModule extends TiModule {

    public ReplModule(TiContext context) {
        super(context);
    }
    
    public ReplServerProxy createReplServer() {
        ReplServerProxy repl = new ReplServerProxy(getTiContext());
        return repl;
    }
}
