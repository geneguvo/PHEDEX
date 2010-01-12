/*
 * Copyright (c) 2009 Nicholas C. Zakas
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
/*
 * Modified to be a non-singleton. Thanks for the code, Nick!
 */
PHEDEX.namespace("Util");
PHEDEX.Util.IdleTimer = function(){
  var idle    = false,        //indicates if the user is idle
      tId     = -1,           //timeout ID
      enabled = false,        //indicates if the idle timer is enabled
      timeout = 30000,        //the amount of time (ms) before the user is considered idle
      YUE     = YAHOO.util.Event;

  var IdleTimer = {
    handleUserEvent: function() {
        clearTimeout(tId);
        if (enabled){
            if (idle){
                this.toggleIdleState();           
            } 
            tId = setTimeout(function(obj) {
              return function() { obj.toggleIdleState(); }
            }(this), timeout);
        }    
    },
    toggleIdleState: function() {

        //toggle the state
        idle = !idle;

        //fire appropriate event
        this.fireEvent(idle ? "idle" : "active");            
    },
    isRunning: function(){
      return enabled;
    },
    isIdle: function(){
      return idle;
    },
    start: function(newTimeout){
      enabled = true;
      idle = false;
      if (typeof newTimeout == "number"){
        timeout = newTimeout;
      }
      YUE.on(document, "mousemove", this.handleUserEvent, this, true);
      YUE.on(document, "keydown",   this.handleUserEvent, this, true);
      tId = setTimeout(function(obj) {
        return function() { obj.toggleIdleState(); }
      }(this), timeout);
    },
    stop: function(){
      enabled = false;
      clearTimeout(tId);
      YUE.removeListener(document, "mousemove", this.handleUserEvent);
      YUE.removeListener(document, "keydown",   this.handleUserEvent);
    }
  };

  YAHOO.lang.augmentObject(IdleTimer, YAHOO.util.EventProvider.prototype);
  IdleTimer.createEvent("active");
  IdleTimer.createEvent("idle");

  return IdleTimer;
};

log('loaded...','info','idletimer');