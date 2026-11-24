{ secrets }:
{
  domain = (secrets.zones.float-play.teleinfotekPlZone or { name = "teleinfotek.pl"; }).name;
  hostname = "mail.teleinfotek.pl";
  smtpHostname = "windows.moe";
  relayAddress = secrets.privateIps.float-play.v6;
  relayPort = 2525;
  nodePorts = [ 30025 30465 30993 30443 30808 ];
}
