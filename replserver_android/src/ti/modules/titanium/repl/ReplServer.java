package ti.modules.titanium.repl;

import java.net.Socket;
import java.net.ServerSocket;
import java.io.InputStreamReader;
import java.io.BufferedReader;
import java.io.OutputStreamWriter;
import java.io.BufferedWriter;
import java.io.PrintWriter;
import java.io.InterruptedIOException;
import java.util.List;
import java.util.ArrayList;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.Callable;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.CancellationException;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.ExecutionException;
import java.lang.reflect.Field;

import org.json.JSONException;
import org.json.JSONObject;

import org.mozilla.javascript.Context;
import org.mozilla.javascript.EcmaError;
import org.mozilla.javascript.EvaluatorException;
import org.mozilla.javascript.ErrorReporter;
import org.mozilla.javascript.Scriptable;

import org.apache.commons.codec.binary.Base64;

import org.appcelerator.titanium.TiDict;
import org.appcelerator.titanium.TiProxy;
import org.appcelerator.titanium.TiContext;
import org.appcelerator.titanium.util.Log;
import org.appcelerator.titanium.kroll.KrollContext;
import org.appcelerator.titanium.kroll.KrollBridge;

public class ReplServer {

    private TiProxy proxy;
    private ReplListener listener = null;
    private int port;

    private static final String LCAT = "ReplServer";
    private static final boolean DBG = true;


    public ReplServer(TiProxy proxy) {
        this.proxy = proxy;
    }

    public void start() {
        if (DBG) { Log.w(LCAT, "Repl Server Start..."); }
        listener = new ReplListener(5051);
        new Thread(listener, "ReplServerListenerThread").start();
    }

    public void stop () {
        if (DBG) { Log.w(LCAT, "Repl Stopping..."); }

        if(null != listener) {
            listener.shutdownRequested = true;
        }
    }

    public int getPort() {
        return port;
    }

    public void setPort(int port) {
        this.port = port;
    }

    public boolean isRunning() {
        return listener != null && !listener.shutdownRequested;
    }

    public String status () {
        if (listener != null && !listener.shutdownRequested) {
            return "RUNNING";
        }
        else {
            return "STOPPED";
        }
    }

    private class ReplListener implements Runnable {
        public int portNumber;
        public ServerSocket listenSocket;
        private List<ReplSession> replSessions;
        public boolean shutdownRequested = false;

        public ReplListener(int port) {
            this.portNumber = port;
            this.replSessions = new ArrayList<ReplSession>();
        }

        public void onReplSessionEnd(ReplSession replSession) {
            replSessions.remove(replSession);
        }

        public void run() {
            try {
                listenSocket = new ServerSocket(portNumber);
                listenSocket.setSoTimeout(500); //500 milliseconds
            }
            catch(Exception e) {
                Log.e(LCAT, "Repl Listener Exception: ..."+e.getMessage(), e);
                return;
            }

            while(!shutdownRequested) {
                try{
                    Socket replSocket = listenSocket.accept();
                    //replSocket.setSoTimeout(500); //500 milliseconds
                    ReplSession replSession = new ReplSession(replSocket, this);
                    replSessions.add(replSession);
                    new Thread(replSession, "ReplSessionThread-"+replSession.uuid).start();
                }
                catch(InterruptedIOException e){
                    //probably happened after timeout
                }
                catch(Exception e) {
                    Log.e(LCAT, "Repl Listener Exception: ..."+e.getMessage(), e);
                }
            }
            //Finished listening, shutdown requested. Clean up.
            try {
                if(null != listenSocket) { listenSocket.close(); }
            }
            catch(Exception e) {
                Log.e(LCAT, "Repl Listener Exception: ..."+e.getMessage(), e);
            }
            //Shutdown all child ReplSessions
            for(ReplSession replSession : replSessions) {
                replSession.stop();
            }
            Log.w(LCAT, "Repl Listener Stopped...");
        }
    }

    private class ReplSession implements Runnable, ErrorReporter{
        public Socket replSocket = null;
        public ReplListener parentListener = null;
        public BufferedReader in = null;
        public PrintWriter out = null;
        public String currentLine = null;
        public String uuid = null;
        public KrollBridge kb = null;
        public KrollContext kc = null;
        public boolean shutdownRequested = false;

        public static final long TIMEOUT_SECONDS = 10L;
        public String PROMPT = "REPL> ";

        public ReplSession(Socket sock, ReplListener parent) {
            this.replSocket = sock;
            this.parentListener = parent;
            kb = getKrollBridgeHack();
            kc = getKrollContextHack();
            uuid = UUID.randomUUID().toString();
        }

        //Yep, ugly
        public KrollBridge getKrollBridgeHack() {
            KrollBridge retval = null;
            try {
                TiContext context = proxy.getTiContext();
                Field krollBridgeField = TiContext.class.getDeclaredField("tiEvaluator");
                krollBridgeField.setAccessible(true);
                KrollBridge kb = (KrollBridge) krollBridgeField.get(context);
                retval = kb;
            }
            catch(NoSuchFieldException e) {
                Log.e(LCAT, "No field: tiEvaluator in TiContext class??");
            }
            catch(IllegalAccessException e) {
                Log.e(LCAT, "Can't access: tiEvaluator in TiContext class??");
            }
            return retval;
        }
        
        //This too is ugly
        public KrollContext getKrollContextHack() {
            KrollContext retval = null;
            if(this.kb == null){
                return retval;
            }
            try {
                Field krollField = KrollBridge.class.getDeclaredField("kroll");
                krollField.setAccessible(true);
                KrollContext kc = (KrollContext) krollField.get(kb);
                retval = kc;
            }
            catch(NoSuchFieldException e) {
                Log.e(LCAT, "No field: kroll in KrollBridge??");
            }
            catch(IllegalAccessException e) {
                Log.e(LCAT, "Can't access: kroll in KrollBridge class??");
            }
            return retval;
        }

        public void prompt() {
            try {
                out.write(PROMPT);
                out.flush();
            }
            catch(Exception e) {
                Log.e(LCAT, "Repl Session Exception: ..."+e.getMessage(), e);
            }
            
        }

        public void printOutput(String output) {
            try {
                out.println(output);
                out.flush();
            }
            catch(Exception e) {
                Log.e(LCAT, "Repl Session Exception: ..."+e.getMessage(), e);
            }
        }

        public void stop() {
            shutdownRequested = true;
        }

        public Object doEvalJS(String src) {
            //XXX--this is meant to be run on the KrollContext thread
            
            //Log.d(LCAT, "doEvalJS evaluating source: " + src);
            Object result = null;
            Context ctx = Context.enter();
            Scriptable jsScope = kc.getScope();
            ctx.setOptimizationLevel(-1);
            ctx.setErrorReporter(this);
            
            try {   
                result = ctx.evaluateString(jsScope, src, "", 0, null);
                //Log.d(LCAT, "doEvalJS result: " + result);                
            } catch (EcmaError e) {
                Log.e(LCAT, "ECMA Error evaluating source: " + e.getMessage(), e);
                result = e;
            } catch (EvaluatorException e) {
                Log.e(LCAT, "Error evaluating source: " + e.getMessage(), e);
                result = e;
            } catch (Throwable e) {
                Log.e(LCAT, "Error evaluating source: " + e.getMessage(), e);
                result = e;
            } finally {
                Context.exit();
            }
            //Log.d(LCAT,"done eval: ...");
            
            return result;
        }

        @Override
	public void error(String message, String sourceName, int line, String lineSource, int lineOffset) {
            Log.e(LCAT, "Error: " + message); 
	}
        
	@Override
	public void warning(String message, String sourceName, int line, String lineSource, int lineOffset) {
            Log.e(LCAT, "Warning: " + message); 
	}
        
	@Override
	public EvaluatorException runtimeError(String message, String sourceName, int line, String lineSource, int lineOffset) {
            Log.e(LCAT, "Runtime Error: " + message);
            return null;
	}
        
        public TiDict processMessage(final TiDict msg) {
            TiDict result = new TiDict();
            boolean timeout = false;
            
            result.put("session-id", msg.getString("session-id"));
            result.put("id", msg.getInt("id"));
            result.put("type", "eval_response");

            FutureTask<Object> future =
                new FutureTask<Object>(new Callable<Object>() {
                        public Object call() {
                            Object result = doEvalJS(msg.getString("src"));
                            //Log.d(LCAT, "ReplSession.processMessage.result: "+result.toString());
                            return result;
                        }});

            try {
                kc.post(future);
                Object futureResult = future.get(TIMEOUT_SECONDS, TimeUnit.SECONDS);
                if(futureResult instanceof Throwable) {
                    //Log.d(LCAT, "ReplSession.future.get: "+futureResult.toString());
                    result.put("status", "error");
                    result.put("result", futureResult);
                }
                else {
                    //Log.d(LCAT, "ReplSession.future.get: "+futureResult.toString());
                    result.put("status", "ok");
                    result.put("result", futureResult);
                }
            } catch (InterruptedException e) {
                Log.d(LCAT, "InterruptedException executing the task", e);
                e.printStackTrace(out);
                result.put("status", "ERROR");
                result.put("result", e);
            } catch (ExecutionException e) {
                Log.d(LCAT, "ExecutionException executing the task", e);
                Log.d(LCAT, "ExecutionException cause", e.getCause());
                e.getCause().printStackTrace(out);
                result.put("status", "ERROR");
                result.put("result", e);
            } catch (TimeoutException e) {
                Log.d(LCAT, "TimeoutException executing the task", e);
                timeout = true;
                e.printStackTrace(out);
                result.put("status", "ERROR");
                result.put("result", e);
            } catch (CancellationException e) {
                Log.d(LCAT, "CancellationException executing the task", e);
                e.printStackTrace(out);
                result.put("status", "ERROR");
                result.put("result", e);
            } finally {
                if (timeout) {
                    future.cancel(true);
                }
            }
            return result;
        }

        public String evalJS(final String jsSrc) throws Exception {
            String result = null;
            boolean timeout = false;
            
            FutureTask<String> future =
                new FutureTask<String>(new Callable<String>() {
                        public String call() {
                            Object result = doEvalJS(jsSrc);
                            //Log.d(LCAT, "ReplSession.evalJS.result: "+result.toString());
                            return result.toString();
                        }});

            try {
                kc.post(future);
                result = future.get(TIMEOUT_SECONDS, TimeUnit.SECONDS);
                //Log.d(LCAT, "ReplSession.future.get: "+result);
            } catch (InterruptedException e) {
                Log.d(LCAT, "InterruptedException executing the task", e);
                result = e.getMessage();
                e.printStackTrace(out);
            } catch (ExecutionException e) {
                Log.d(LCAT, "ExecutionException executing the task", e);
                Log.d(LCAT, "ExecutionException cause", e.getCause());
                result = e.getMessage();
                e.getCause().printStackTrace(out);
            } catch (TimeoutException e) {
                Log.d(LCAT, "TimeoutException executing the task", e);
                timeout = true;
                result = e.getMessage();
                e.printStackTrace(out);
            } catch (CancellationException e) {
                Log.d(LCAT, "CancellationException executing the task", e);
                result = e.getMessage();
                e.printStackTrace(out);
            } finally {
                if (timeout) {
                    future.cancel(true);
                }
            }
            return result;
        }

        public void run() {

            try {
                in = new BufferedReader(new InputStreamReader(replSocket.getInputStream()));
                out = new PrintWriter(new BufferedWriter(new OutputStreamWriter(replSocket.getOutputStream())));

                currentLine = null;
                out.println("Welcome the the REPL Server"); //need to pull project name into here
                prompt();

                while(!shutdownRequested) {
                    while(!shutdownRequested && !in.ready()) {
                        try {
                            Thread.sleep(500);
                        } catch (InterruptedException e) {
                            Log.e(LCAT, "ReplSession.InterruptedException"+e.getMessage(), e);
                        }
                    }

                    if(shutdownRequested) {
                        Log.d(LCAT, "ReplSession.shutdownRequested...: ");
                        break;
                    }

                    currentLine = in.readLine();
                    //Log.d(LCAT, "ReplSession.line: "+currentLine);
                    if (currentLine.equals("/q") || currentLine.equals("/quit")) {
                        Log.d(LCAT, "ReplSession.quitting...: ");
                        out.println("Bye!");
                        out.flush();                        
                        break;
                    }
                    else if(currentLine.startsWith("/session_id")) {
                        out.println("/session_id "+uuid);
                        out.flush();
                        prompt();
                    }
                    else if(currentLine.startsWith("/message ")) {
                        String rawmsg = currentLine.substring(8);
                        //Log.d(LCAT, "ReplSession.got message: "+rawmsg);
                        try {
                            String jsonmsg = new String(Base64.decodeBase64(rawmsg.getBytes()));
                            //Log.d(LCAT, "ReplSession.got jsonmsg: "+jsonmsg);
                            JSONObject json = new JSONObject(jsonmsg);
                            //Log.d(LCAT, "ReplSession.got json: "+json);
                            TiDict msgDict = new TiDict(json);
                            //Log.d(LCAT, "ReplSession.got msgDict: "+msgDict);
                            TiDict respDict = processMessage(msgDict);

                            String respJson = respDict.toString();
                            String resp64 = new String(Base64.encodeBase64(respJson.getBytes()));
                            out.println("/message_response "+resp64);
                            out.flush();
                            prompt();
                        } catch (JSONException jse) {
                            Log.w(LCAT, "Unable to JSON decode msg: " + rawmsg);
                        } catch (Exception e) {
                            Log.e(LCAT, "ReplSession.processMessage: "+e.getMessage(), e);
                        }

                    } else {
                        String result = evalJS(currentLine);
                        out.println(result);
                        out.flush();
                        prompt();
                    }
                }
            }
            catch(Exception e) {
                Log.e(LCAT, "ReplSession Exception: ..."+e.getMessage(), e);
            }
            finally {
                if(null != in) {
                    try { in.close(); } catch (Exception ig) { }
                }
                if(null != out) {
                    try { out.close(); } catch (Exception ig) { }
                }
                if (null != replSocket) {
                    try { replSocket.close(); } catch (Exception ig) { }
                }
                this.parentListener.onReplSessionEnd(this);
                Log.d(LCAT, "ReplSession.finally...: END RUN");
            }
        }
    }
}
