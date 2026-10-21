// HinterOS: the Jellyfin app on this box signs in by itself (design/server.md, spike S1). The
// session daemon starts the app on this page, served by Jellyfin at /web/hinteros/signin.html, with
//   #s=<ServerId>&u=<UserId>&d=<DeviceId>&AccessToken=<token>
// (a token hinteros-system made for the profile's own Jellyfin user). The page stores
// jellyfin-web's own login for this server (localStorage `jellyfin_credentials`, the format of
// jellyfin-apiclient's Credentials, and the device id `_deviceId2`), removes the fragment and
// opens the web UI, which is then signed in. It runs on every start: a sign-out or a new token
// is fixed the next time.
(function () {
  "use strict";
  var p = new URLSearchParams(location.hash.slice(1));
  // The token never stays in the address or the history.
  history.replaceState(null, "", location.pathname);
  var id = p.get("s");
  var user = p.get("u");
  var token = p.get("AccessToken");
  var device = p.get("d");
  if (id && user && token) {
    var creds;
    try {
      creds = JSON.parse(localStorage.getItem("jellyfin_credentials") || "{}") || {};
    } catch (e) {
      creds = {};
    }
    var servers = Array.isArray(creds.Servers) ? creds.Servers : [];
    var old = servers.filter(function (s) { return s && s.Id === id; })[0] || {};
    var server = Object.assign({}, old, {
      Id: id,
      ManualAddress: location.origin,
      LastConnectionMode: 2, // manual
      AccessToken: token,
      UserId: user,
      DateLastAccessed: Date.now()
    });
    creds.Servers = [server].concat(servers.filter(function (s) { return s && s.Id !== id; }));
    localStorage.setItem("jellyfin_credentials", JSON.stringify(creds));
    if (device) {
      localStorage.setItem("_deviceId2", device);
    }
  }
  location.replace("/web/index.html");
})();
