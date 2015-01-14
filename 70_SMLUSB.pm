#################################################################################
# 70_SMLUSB.pm
# Module for FHEM to receive SML Data via USB Schreiblesekopf by Udo
#
# http://wiki.volkszaehler.org/hardware/controllers/ir-schreib-lesekopf-usb-ausgang
#
# Developed for and tested with EHM ED 300 L power meter
#
# Used module 70_USBWX.pm as template. Thanks to Willi Herzig
#
# Matthias Rammes
#
##############################################
# $Id: 70_SMLUSB.pm 1000 2013-09-10 19:54:04Z matzefisi $
package main;

use strict;
use warnings;
use Device::SerialPort;

use vars qw{%attr %defs};

my %obiscodes = (
 '77070100010800FF' => 'Zählerstand-Bezug-Total',
 '77070100020800FF' => 'Zählerstand-Lieferung-Total',
 '77070100010801FF' => 'Zählerstand-Tarif-1-Bezug',
 '77070100020801FF' => 'Zählerstand-Tarif-1-Lieferung',
 '77070100010802FF' => 'Zählerstand-Tarif-2-Bezug',
 '77070100020802FF' => 'Zählerstand-Tarif-2-Lieferung',
 '770701000F0700FF' => 'Momentanleistung',
 '77070100100700FF' => 'Momentanleistung');

#####################################
sub
SMLUSB_Initialize($)
{
  require "$attr{global}{modpath}/FHEM/DevIo.pm";
  my ($hash) = @_;
  $hash->{ReadFn}     = "SMLUSB_Read";
  $hash->{ReadyFn}    = "SMLUSB_Ready"; 
  $hash->{DefFn}      = "SMLUSB_Define";
  $hash->{UndefFn}    = "SMLUSB_Undef"; 
  $hash->{GetFn}      = "SMLUSB_Get";
  $hash->{ParseFn}    = "SMLUSB_Parse";
  $hash->{StateFn}    = "SMLUSB_SetState";
  $hash->{Match}      = ".*";
  $hash->{AttrList}   = $readingFnAttributes;
  $hash->{ShutdownFn} = "SMLUSB_Shutdown";

}

#####################################
sub
SMLUSB_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);
  return "wrong syntax: 'define <name> SMLUSB <devicename>\@baudrate'"
    if(@a < 3);

  DevIo_CloseDev($hash);

  my $name = $a[0];
  my $dev = $a[2];
        
  $hash->{fhem}{interfaces} = "power";

  if($dev eq "none") {
	Log3 $hash, 1,"SMLUSB $name device is none, commands will be echoed only";
    	$attr{$name}{dummy} = 1;
    	return undef;
  }

  $attr{$name}{"event-min-interval"} = ".*:30";
  
  $hash->{DeviceName}   = $dev;
  
  Log3 $hash, 5, "SMLUSB: Defined";
 
  my $ret = DevIo_OpenDev($hash, 0, "SMLUSB_DoInit");
  
  return $ret;
} 


#####################################
sub
SMLUSB_Ready($)
{
  my ($hash) = @_;
  return DevIo_OpenDev($hash, 0, "SMLUSB_DoInit")
	if($hash->{STATE} eq "disconnected");

} 

#####################################
sub
SMLUSB_SetState($$$$)
{
  my ($hash, $tim, $vt, $val) = @_;
  return undef;
}
#####################################
sub
SMLUSB_Clear($)
{
my $hash = shift;
my $buf;
# clear buffer:
if($hash->{SMLUSB}) 
   {
   while ($hash->{SMLUSB}->lookfor()) 
      {
      $buf = DevIo_DoSimpleRead($hash);
      $buf = uc(unpack('H*',$buf));
      }
   }

return $buf;
} 

#####################################
sub
SMLUSB_DoInit($)
{
my $hash = shift;
my $name = $hash->{NAME}; 
my $init ="?";
my $buf;

SMLUSB_Clear($hash); 

return undef; 
}

#####################################
sub SMLUSB_Undef($$)
{
my ($hash, $arg) = @_;
my $name = $hash->{NAME};
delete $hash->{FD};
$hash->{STATE}='close';
$hash->{SMLUSB}->close() if($hash->{SMLUSB});
Log3 $hash, 0, "SMLUSB: Undefined";
return undef;
} 

#####################################
# called from the global loop, when the select for hash->{FD} reports data
# This function reads the RAW hex data and hands over the data to parse function when a SML end is detected
# ToDo: Generalize this, so that also other protocols are supported
sub
SMLUSB_Read($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $char;

  my $mybuf = DevIo_DoSimpleRead($hash);
  $mybuf = uc(unpack('H*',$mybuf));

  my $usbdata = $hash->{helper}{PARTIAL};
  
  if(!defined($mybuf) || length($mybuf) == 0) {
  	SMLUSB_Disconnected($hash);
   	return "";
  }

  # Find the end of a SML file
  # Source: http://de.wikipedia.org/wiki/Smart_Message_Language
  # ToDo: Sometimes the beginning (1B1B1B1B010101) is not complete. We should clarify this.
  
  if ((defined $hash->{helper}{PARTIAL}) and ($hash->{helper}{PARTIAL} =~ m/1B1B1B1B1A[0-9A-F]{6}$/)) {
        Log3 $hash, 5, "SMLUSB: End of SML found. Looking for a beginning.";
        if ($hash->{helper}{PARTIAL} =~ m/^1B1B1B1B01010101/) {
          SMLUSB_Parse($hash, $hash->{helper}{PARTIAL} );
          $hash->{helper}{PARTIAL} = "";
          Log3 $hash, 5, "SMLUSB: Beginning of SML File found start parsing";
        } else {
          if ($hash->{helper}{PARTIAL} =~ m/^(1B){0,4}01010101/) {
            $hash->{helper}{PARTIAL} =~ s/^(1B){0,4}01010101/1B1B1B1B01010101/g;
            SMLUSB_Parse($hash, $hash->{helper}{PARTIAL} );
            $hash->{helper}{PARTIAL} = "";
            Log3 $hash, 5, "SMLUSB: Partial beginning of SML File found. Repaired and  start parsing";
          } else {
            #Log3 $hash, 5, "SMLUSB: No beginning of SML File found. Try it anyway, but no guarantee :) -> ". substr($hash->{helper}{PARTIAL},0,50);
            #SMLUSB_Parse($hash, $hash->{helper}{PARTIAL} );
            $hash->{helper}{PARTIAL} = "";
          }
        }
  } else {
  	$usbdata .= $mybuf;
	$hash->{helper}{PARTIAL} = $usbdata;
	$hash->{PARTIAL} = "";
  }

} 

#####################################
sub
SMLUSB_Shutdown($)
{
  my ($hash) = @_;
  return undef;
  Log3 $hash, 0, "SMLUSB: Shutdown";
}

#####################################
sub
SMLUSB_Get($@)
{
my ($hash, @a) = @_;
	
my $msg;
my $name=$a[0];
my $reading= $a[1];
$msg="$name => No Get function ($reading) implemented";
return $msg;
} 

#####################################
sub
SMLUSB_Parse($$)
{
  my ($hash,$rmsg) = @_;

  my $telegramm;
  my $scaler;
  my $unit;
  my $direction = "Bezug";

  my $length_all = 0;
  my $length_value = 0;

  my $smlfile = $rmsg;

  # Try to find a SML telegramm in the SML file

  Log3 $hash, 5, "SMLUSB: Started parsing";

  readingsBeginUpdate($hash);

  while ($smlfile =~ m/7707[0-9A-F]{10}FF[0-9A-F]{16,9999}/) {
    $telegramm = $&;

    # Try to find the OBIS code in the hash of known and supported OBIS codes
    # OBIS Code with the start (7707) is always 8 bit long (16 nible)
 
    if (defined $obiscodes{substr($telegramm,0,16)}) {
    
      # OBIS code found start parsing
    
      $length_all   = 16;    
      $length_value = 0;

      # Detect length of status word (very static at the moment)
      # You can find more information if you google for type length field
      # 01 = Statusword not set
      # 62 is (6 = no more tl fields and type = unsigned?, 2 = 2 bytes or 4 hex chars)
    
      $length_all+=hexstr_to_signed32int(substr($telegramm,17,1))*2+2;

      # Detect the direction of engergy from the status word
  
      $direction = "Bezug"       if (substr($telegramm,$length_all-4,2) eq "82");
      $direction = "Einspeisung" if (substr($telegramm,$length_all-4,2) eq "A2");
      
      # Detect the unit. Also very static and could be improved

		  if (substr($telegramm,$length_all,4) eq "621E") {
			$unit = "W/h"; }
		  else {
			$unit = "W"; }

      $length_all+=4;

      # Detect the scaler. Also very static and could be improved

      $scaler=10 if (substr($telegramm,$length_all,4) eq "52FF"); 
      $scaler=1  if (substr($telegramm,$length_all,4) eq "5200");
      $scaler=1  if (substr($telegramm,$length_all,4) eq "5201");
      
      Log3 $hash, 5, "SMLUSB: SML Telegram found: $telegramm - Scaler: " . substr($telegramm,$length_all,4);

      $length_all+=4;

      # Detect the value length.

      $length_value=hexstr_to_signed32int(substr($telegramm,$length_all+1,1))*2;
      $length_all+=2;   
   
      # If value is bigger than 9999 W/h change to kW/h 

		if (sprintf("%.2f",hexstr_to_signed32int(substr($telegramm,$length_all,$length_value-2))/$scaler) > 9999) { 
			$scaler = 10000; 
			$unit = "kW/h"; }

      # Output of results only if a meaningful value is found. Otherwise nothing happens.

		if (sprintf("%.2f",hexstr_to_signed32int(substr($telegramm,$length_all,$length_value-2))/$scaler) > 0) {
			Log3 $hash, 5, "SMLUSB: Reading BulkUpdate. Value > 0";
			
			if ((substr($telegramm,0,16) eq "770701000F0700FF") || (substr($telegramm,0,16) eq "77070100100700FF")) {
				Log3 $hash, 5, "SMLUSB: Setting state";
				$hash->{STATE}="$unit: " . sprintf("%.2f",hexstr_to_signed32int(substr($telegramm,$length_all,$length_value-2))/$scaler) . " - $direction";
					if ($direction eq "Einspeisung") {
						readingsBulkUpdate($hash, $obiscodes{substr($telegramm,0,16)}, sprintf("%.2f",hexstr_to_signed32int(substr($telegramm,$length_all,$length_value-2))/$scaler*-1));
					}
					else {
						readingsBulkUpdate($hash, $obiscodes{substr($telegramm,0,16)}, sprintf("%.2f",hexstr_to_signed32int(substr($telegramm,$length_all,$length_value-2))/$scaler));
					}
			}
			else {
				readingsBulkUpdate($hash, $obiscodes{substr($telegramm,0,16)}, sprintf("%.2f",hexstr_to_signed32int(substr($telegramm,$length_all,$length_value-2))/$scaler));
			}
		}
	}	
    else {
      # If no known OBIS code can be found the telegramm will be ignored (or logged)
      # print "No Obis Code found!: " . substr($telegramm,0,16) ."\n"; 
      # The telegramm  header needs at least to be removed from the smlfile to detect the next one.
      $length_all=16; 
    }
 
    # Remove found telegram from remaining sml file.  
    $smlfile = substr($smlfile,index($smlfile,$&)+$length_all+$length_value,length($smlfile));
  }

  # No good crc16 function found or developed yet. This is a todo
  #my $crc = substr($smlfile,length($smlfile)-4,4);
  #print "CRC: $crc - \n";

  Log3 $hash, 5, "SMLUSB: Parsing ended";

  readingsEndUpdate($hash, 1); 

  return undef;
}

#####################################
sub hexstr_to_signed32int {
    my ($hexstr) = @_;
    #die "Invalid hex string: $hexstr"
    #    if $hexstr !~ /^[0-9A-Fa-f]{1,8}$/;
 
    my $num = hex($hexstr);
    return $num >> 31 ? $num - 2 ** 32 : $num;
}
#####################################
sub
SMLUSB_Disconnected($)
{
  my $hash = shift;
  my $dev = $hash->{DeviceName};
  my $name = $hash->{NAME};
 	
  return if(!defined($hash->{FD})); # Already deleted
	
  #SMLUSB_CloseDev($hash);
  DevIo_CloseDev($hash);

  $readyfnlist{"$name.$dev"} = $hash; # Start polling
  $hash->{STATE} = "disconnected";
	
  # Without the following sleep the open of the device causes a SIGSEGV,
  # and following opens block infinitely. Only a reboot helps.
  sleep(5);

  DoTrigger($name, "DISCONNECTED");
} 



1;

=pod
=begin html

<a name="SMLUSB"></a>
<h3>SMLUSB</h3>
<ul>
  The SMLUSB module interprets SML Files which are received over a serial connection.</br>
  You can use for example the USB IR Read and write head from volkszaehler.org project.</br>
  <br><br>

  <a name="SMLUSBdefine"></a>
  <b>Define</b>
  <ul>
    <code>define <name> SMLUSB <devicename>\@baudrate'</code>
    <br>
    <br>Defines the device over a serial port<br>
    </pre>
  </ul>

  <a name="SMLUSBattr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#event-min-interval">event-min-interval</a></li>
  </ul>
  <br>
</ul>

=end html
=cut
