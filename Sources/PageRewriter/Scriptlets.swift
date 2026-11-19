import FirewallPolicy
import Foundation

/// The scriptlets' own code (#683): small, written here, not copied, one
/// function per name in `Scriptlet.known`. Each runs in the page before its
/// own scripts, inside a try, so one that fails never stops the page.
public enum ScriptletCode {
    /// The script a page is given for its scriptlets, or nil for none.
    public static func script(for scriptlets: [Scriptlet]) -> String? {
        let calls = scriptlets.compactMap { scriptlet -> String? in
            guard functions[scriptlet.name] != nil,
                  let arguments = try? JSONSerialization.data(withJSONObject: scriptlet.arguments),
                  let json = String(data: arguments, encoding: .utf8) else { return nil }
            return "try{nm[\(quoted(scriptlet.name))].apply(null,\(json))}catch(e){}"
        }
        guard !calls.isEmpty else { return nil }
        let used = Set(scriptlets.map(\.name)).sorted().compactMap { name in functions[name].map { "\(quoted(name)):\($0)" } }
        return "(function(){var nm={" + shared + used.joined(separator: ",") + "};" + calls.joined() + "})();"
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Helpers the functions share, as members of `nm` (names start with _).
    static let shared = """
    _value:function(v){if(v==="true")return true;if(v==="false")return false;if(v==="null")return null;\
    if(v==="undefined")return undefined;if(v==="noopFunc")return function(){};if(v==="trueFunc")return function(){return true};\
    if(v==="falseFunc")return function(){return false};if(v==="''"||v==="emptyStr")return "";\
    if(/^-?\\d+$/.test(v))return parseInt(v,10);return undefined},\
    _match:function(n){if(!n)return function(){return true};var m=/^\\/(.+)\\/([a-z]*)$/.exec(n);\
    if(m){var r=new RegExp(m[1],m[2]);return function(s){return r.test(String(s))}}return function(s){return String(s).indexOf(n)>=0}},\
    _prune:function(o,paths){var hit=false;paths.forEach(function(p){var parts=p.split("."),t=o;\
    for(var i=0;i<parts.length-1&&t;i++)t=t[parts[i]];if(t&&typeof t==="object"&&parts[parts.length-1] in t)\
    {delete t[parts[parts.length-1]];hit=true}});return hit},
    """

    static let functions: [String: String] = [
        // set-constant(chain, value): the property reads as `value` from now on.
        "set-constant": """
        function(chain,value){var v=nm._value(value);if(v===undefined&&value!=="undefined")return;var parts=chain.split("."),\
        owner=window;for(var i=0;i<parts.length-1;i++){if(!(parts[i] in owner)){var o={};owner[parts[i]]=o}owner=owner[parts[i]];\
        if(owner===null||typeof owner!=="object"&&typeof owner!=="function")return}Object.defineProperty(owner,\
        parts[parts.length-1],{get:function(){return v},set:function(){},configurable:false})}
        """,
        // abort-on-property-read(chain): reading it throws, so the script using it stops.
        "abort-on-property-read": """
        function(chain){var parts=chain.split("."),owner=window;for(var i=0;i<parts.length-1;i++){owner=owner[parts[i]];\
        if(!owner)return}Object.defineProperty(owner,parts[parts.length-1],{get:function(){throw new ReferenceError("nm")},\
        set:function(){},configurable:false})}
        """,
        // abort-on-property-write(name): setting it throws.
        "abort-on-property-write": """
        function(name){Object.defineProperty(window,name,{get:function(){},set:function(){throw new ReferenceError("nm")},\
        configurable:false})}
        """,
        // abort-current-script(chain, needle): reading it throws inside a script whose text matches.
        "abort-current-script": """
        function(chain,needle){var test=nm._match(needle),parts=chain.split("."),owner=window;for(var i=0;i<parts.length-1;i++)\
        {owner=owner[parts[i]];if(!owner)return}var key=parts[parts.length-1],d=Object.getOwnPropertyDescriptor(owner,key),\
        value=owner[key];Object.defineProperty(owner,key,{get:function(){var s=document.currentScript;\
        if(s&&test(s.textContent||s.src))throw new ReferenceError("nm");return d&&d.get?d.get.call(this):value},\
        set:function(v){if(d&&d.set)d.set.call(this,v);else value=v},configurable:true})}
        """,
        // json-prune(paths, required): drops those paths from JSON the page reads.
        "json-prune": """
        function(paths,required){var ps=String(paths||"").split(" ").filter(Boolean),req=String(required||"").split(" ")\
        .filter(Boolean);if(!ps.length)return;function fix(o){if(!o||typeof o!=="object")return o;if(req.length&&!req.every\
        (function(p){var t=o;p.split(".").forEach(function(k){t=t&&t[k]});return t!==undefined}))return o;nm._prune(o,ps);\
        return o}var parse=JSON.parse;JSON.parse=function(){return fix(parse.apply(this,arguments))};\
        if(window.Response){var json=Response.prototype.json;Response.prototype.json=function(){return json.apply(this,\
        arguments).then(fix)}}}
        """,
        // remove-class(classes, selector): takes those classes off, now and as the page changes.
        "remove-class": """
        function(classes,selector){var cs=String(classes).split("|").filter(Boolean);function go(){var q=selector||cs.map\
        (function(c){return "."+c}).join(",");document.querySelectorAll(q).forEach(function(e){cs.forEach(function(c)\
        {e.classList.remove(c)})})}if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",go);\
        else go();new MutationObserver(go).observe(document.documentElement,{childList:true,subtree:true})}
        """,
        // remove-attr(attrs, selector): takes those attributes off, now and as the page changes.
        "remove-attr": """
        function(attrs,selector){var as=String(attrs).split("|").filter(Boolean);function go(){var q=selector||as.map\
        (function(a){return "["+a+"]"}).join(",");document.querySelectorAll(q).forEach(function(e){as.forEach(function(a)\
        {e.removeAttribute(a)})})}if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",go);\
        else go();new MutationObserver(go).observe(document.documentElement,{childList:true,subtree:true})}
        """,
        // no-setTimeout-if(needle, delay): a timer whose code matches never runs.
        "no-setTimeout-if": """
        function(needle,delay){var test=nm._match(needle),d=delay===undefined||delay===""?null:parseInt(delay,10),\
        set=window.setTimeout;window.setTimeout=function(f,t){if(test(f)&&(d===null||d===t))return 0;\
        return set.apply(this,arguments)}}
        """,
    ]
}
