// this sets the background color of the master UIView (when there are no windows/tab groups on it)
Titanium.UI.setBackgroundColor('#000');

//var repl = Titanium.Repl.createReplServer();
var replserverModule = require('com.evocomputing.replserver');
Ti.API.info("module is => "+replserverModule);

var repl = replserverModule.createReplServer({'listenPort' : 5071});

//show getting/setting properties
Ti.API.info("repl: "+repl);
Ti.API.info("repl.port: "+repl.listenPort);
repl.listenPort = 5061;
Ti.API.info("repl.port: "+repl.listenPort);
Ti.API.info("repl.isRunning: "+repl.running);

repl.start();

Ti.API.info("replserver.isRunning: "+repl.running);

// create tab group
var tabGroup = Titanium.UI.createTabGroup();


//
// create base UI tab and root window
//
var win1 = Titanium.UI.createWindow({  
    title:'Tab 1',
    backgroundColor:'#fff'
});
var tab1 = Titanium.UI.createTab({  
    icon:'KS_nav_views.png',
    title:'Tab 1',
    window:win1
});

var label1 = Titanium.UI.createLabel({
    color:'#999',
    text:'I am Window 1',
    font:{fontSize:20,fontFamily:'Helvetica Neue'},
    textAlign:'center',
    width:'auto'
});

win1.add(label1);

function replButtonStatus() {
  if(repl.isRunning()) {
    return "Stop Server";
  }
  else {
    return "Start Server";
  }
}

var replButton = Titanium.UI.createButton({
    title: replButtonStatus(),
    
});

replButton.addEventListener('click',function(e) {
  if(repl.isRunning()) {
    repl.stop();
    replButton.title = replButtonStatus();
  }
  else {
    repl.start();
    replButton.title = replButtonStatus();
  }
});

win1.add(replButton);

win1.addEventListener('close', function(e) {
    Ti.API.info("win1 close");
    repl.stop();
});

//
// create controls tab and root window
//
var win2 = Titanium.UI.createWindow({  
    title:'Tab 2',
    backgroundColor:'#fff'
});
var tab2 = Titanium.UI.createTab({  
    icon:'KS_nav_ui.png',
    title:'Tab 2',
    window:win2
});

var label2 = Titanium.UI.createLabel({
	color:'#999',
	text:'I am Window 2',
	font:{fontSize:20,fontFamily:'Helvetica Neue'},
	textAlign:'center',
	width:'auto'
});

win2.add(label2);



//
//  add tabs
//
tabGroup.addTab(tab1);  
tabGroup.addTab(tab2);  


// open tab group
tabGroup.open();
