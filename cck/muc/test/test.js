<HTML>

<HEAD>
<TITLE>Account Setup</TITLE>
<SCRIPT LANGUAGE = "JavaScript">

	// * configure dialer for Registration Server
	dialerData = new Array();
	
	dialerData[ 0 ]  = "FileName=REGSERV.IAS";
	dialerData[ 1 ]  = "AccountName=test";
	dialerData[ 2 ]  = "ISPPhoneNum=+1 (800) 638-8290";
	dialerData[ 3 ]  = "LoginName=mozillarama";
	dialerData[ 4 ]  = "Password=YWg0ZrhvamYLZix1ADRvdWpttnp3";
	dialerData[ 5 ]  = "DNSAddress=205.217.225.10";
	dialerData[ 6 ]  = "DNSAddress2=205.217.225.20";
	dialerData[ 7 ]  = "DomainName=netscape.com";
	dialerData[ 8 ]  = "IPAddress=0.0.0.0";
	dialerData[ 9 ]  = "IntlMode=FALSE";
	dialerData[ 10 ] = "DialOnDemand=TRUE";
	dialerData[ 11 ] = "ModemName=dontknow";
	dialerData[ 12 ] = "ModemType=dontknow";
	dialerData[ 13 ] = "DialType=1"
	dialerData[ 14 ] = "OutsideLineAccess=9";
	dialerData[ 15 ] = "DisableCallWaiting=FALSE";
	dialerData[ 16 ] = "DisableCallWaitingCode=";
	dialerData[ 17 ] = "UserAreaCode=650";				// XXX what to do if international mode?
	dialerData[ 18 ] = "CountryCode=1";
	dialerData[ 19 ] = "LongDistanceAccess=1";									// XXX
	dialerData[ 20 ] = "DialAsLongDistance=TRUE";									// XXX
	dialerData[ 21 ] = "DialAreaCode=TRUE";										// XXX
	dialerData[ 22 ] = "ScriptEnabled=no";
	dialerData[ 23 ] = "ScriptFileName=";
	dialerData[ 24 ] = "NeedsTTYWindow=no";
	dialerData[ 25 ] = "Location=Home";
 	dialerData[ 26 ] = "DisconnectTime=99";
	dialerData[ 27 ] = "Path=Server";

	navigator.dialer.DialerConfig( dialerData );

</SCRIPT>
</HEAD>
<BODY>
test of the emergency dialing system
</BODY>
</HTML>
