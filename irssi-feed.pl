# by Julius Michaelis <iRRSi@cserv.dyndns.org>
#
# uses XML::Feed (yep, libxml-feed-perl has huge dependencies...)

use strict;
use warnings;
use feature 'state';
use Data::Dumper; # TODO: rem
use XML::Feed;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use List::Util qw(min);
use IO::Socket::INET;
use Errno;
our $VERSION = "20121020";
our %IRSSI = (
	authors     => 'Julius Michaelis',
	contact     => 'iRRSi@cserv.dyndns.org',
	name        => 'iRSSi feed reader',
	description => 'Parses and announces XML/Atom feeds',
	license     => 'GPLv3',
	changed     => '$VERSION',
);
use Irssi qw(command_bind timeout_add INPUT_READ INPUT_WRITE);

sub save_config {
	our @feeds;
	my $str = '';
	foreach my $feed (@feeds) {
		if(defined $feed) { # this will be the only function with extra security against invalid stuff..
			$str .= $feed->{uri} . " " . $feed->{timeout} . "\n"
		}
	}
	Irssi::settings_set_str('feedlist', $str);
}

sub initialize {
	our @feeds;
	foreach(split(/\n/,Irssi::settings_get_str('feedlist'))) {
		my ($uri, $timeout) = split / /, $_;
		feed_new($uri, $timeout);
	}
	feedprint("Loaded ".($#feeds+1)." feeds");
	check_feeds();
}

sub feedreader_cmd {
	my ($data, $server, $witem) = @_;
	my @args = split(/ /, $data);
	my $cmd = shift @args;
	if($cmd eq "add") {
		our @feeds;
		my ($uri, $timeout) =  @args;
		foreach(@feeds) {
			if($_->{uri} eq $uri || $_->{id} eq $uri) {
				feedprint("Failed to add/modify feed " . feed_stringrepr($_) . ": Already exists");
				return
			}
		}
		my $feed = feed_new($uri, $timeout);
		feedprint("Added feed " . $feed->{name});
		save_config();
		check_feeds();
	} elsif ($cmd eq "set") {
		our @feeds;
		my ($uri, $timeout) =  @args;
		foreach(@feeds) {
			if(not defined $uri || $_->{uri} eq $uri || $_->{id} eq $uri) {
				$timeout //= $_->{timeout};
				$timeout = 3600 if $timeout > 3600;
				$timeout = 10 if $timeout < 10;
				$_->{timeout} = $timeout;
				$_->{active} = 1;
				$_->{io}->{failed} = 0;
				save_config();
				check_feeds();
				feedprint("Next check timeout for ". feed_stringrepr($_));
				return;
			}
		}
		check_feeds();
		feedprint("Feed not found: $uri");
	} elsif ($cmd eq "list") {
		our @feeds;
		if($#feeds < 0) {
			feedprint("Feed list: empty");
		} else {
			feedprint("Feed list:");
			foreach my $feed (@feeds) {
				feedprint("   " . feed_stringrepr($feed));
			}
		}
		check_feeds(); # for the lulz
	} elsif ($cmd eq "rem" || $cmd eq "rm") {
		my ($remove) = @args;
		our @feeds;
		if(defined $remove) {
			my $foundone = 0;
			foreach my $feed (@feeds) {
				if($feed->{id} eq $remove || $feed->{uri} eq $remove) {
					feed_delete($feed);
					feedprint("Feed deleted: " . feed_stringrepr($feed));
					$foundone = 1;
				}
			}
			feedprint("Could not find feed $remove.") if(!$foundone);
		} else {
			my $foundone = 0;
			foreach(@feeds) {
				if(not $_->{active}) {
					$_->delete;
					feedprint("Feed deleted: " . feed_stringrepr($_));
					$foundone = 1;
				}
			}
			feedprint("No inactive feeds.") if(!$foundone);
		}
		save_config;
	} elsif ($cmd eq "eval") {
		feedprint(Dumper(eval (substr($data, 5))));
	} else {
		feedprint("Unknown command: /feed $data");
	}
}

sub all_feeds_gen1 { our @feeds; $_->{generation} || return 0 for @feeds; 1 }

sub check_feeds {
	state $timeoutcntr = 0;
	my $thistimeout = shift // $timeoutcntr;
	our @feeds;
	#feedprint("check! $thistimeout $timeoutcntr");
	my @news; 
	foreach my $feed (@feeds) {
		push @news, feed_get_news($feed);
	}
	my $nulldate = DateTime->new(year => 0);
	feedprint($_->title ." - ". $_->link) foreach sort { ($a->issued // $nulldate) > ($b->issued // $nulldate) } grep {defined $_} @news;
	my $nextcheck = ((min(map { feed_check($_) } @feeds)) // 0) + 1;
	if($thistimeout == $timeoutcntr) {
		my $fivemin = clock_gettime(CLOCK_MONOTONIC) + 301;
		$nextcheck = $fivemin if $nextcheck > $fivemin;
		my $timeout = $nextcheck - clock_gettime(CLOCK_MONOTONIC);
		$timeout = 5 if $timeout < 5;
		$timeoutcntr += 1;
		my $hackcopy = $timeoutcntr; # to avoid passing a reference. I don't understand why it happens
		Irssi::timeout_add_once(1000 * $timeout, \&check_feeds, $hackcopy) if((scalar(grep { $_->{active} } @feeds)) > 0);
		#feedprint("$hackcopy check in $timeout.")  if((scalar(grep { $_->{active} } @feeds)) > 0);
	}
	our $initial_skips;
	if($initial_skips && all_feeds_gen1()) {
		feedprint("Skipped $initial_skips feed entries.");
		$initial_skips = 0;
	}
}

sub feed_new {
	my $uri = shift;
	my $timeout = shift // 120;
	state $nextfid = 1;
	my $feed = {
		id => $nextfid,
		uri => URI->new($uri),
		name => $uri,
		lastcheck => clock_gettime(CLOCK_MONOTONIC) - 86400,
		timeout => $timeout,
		active => 1, # use to deactivate when an error has been encountered.
		itemids => {"dummy" => -1},
		generation => 0,
		io => {
			readtag => 0,
			writetag => 0,
			conn => 0,
			failed => 0,
			state => 0,
			buffer => '',
			xml => 0,
		},
	};
	$nextfid += 1;
	our @feeds;
	push(@feeds, $feed);
	if($feed->{uri}->scheme ne 'http') {
		$feed->{active} = 0;
		if($feed->{uri}->scheme eq 'https') {
			$feed->{uri}->scheme('http');
			feedprint(feed_stringrepr($feed) . " has https uri, https is not supported. Do /feed set " . $feed->{id} . " to reactivate with http.");
		} else {
			feedprint("Unsupported uri scheme ".$feed->{uri}->scheme." in feed " . feed_stringrepr($feed));
		}
	}
	return $feed;
}

sub feed_check {
	my $feed = shift;
	return if(not $feed->{active});
	my $now = clock_gettime(CLOCK_MONOTONIC);
	if(($now - $feed->{lastcheck}) > $feed->{timeout}) {
		if($feed->{io}->{failed} >= 3) {
			$feed->{active} = 0;
			$feed->{generation} += 1; # so the "Skipped" message won't hang forever
			return 0;
		}
		feedprint("Warning, stall feed " . $feed->{id}) if($feed->{io}->{conn});
		feed_cleanup_conn($feed,1);
		my $conn = $feed->{io}->{conn} = IO::Socket::INET->new(
			Blocking => 0,
			Proto => 'tcp',
			PeerHost => $feed->{uri}->host,
			PeerPort => $feed->{uri}->port,
			#Timeout => DO NOT SET TIMEOUT. It will activate blocking io...
		);
		$feed->{io}->{readtag}  = Irssi::input_add(fileno($conn), INPUT_READ,  \&feed_io_event_read, $feed);
		$feed->{io}->{writetag} = Irssi::input_add(fileno($conn), INPUT_WRITE, \&feed_io_event_write, $feed);
		$feed->{io}->{failed} += 1;
		$feed->{lastcheck} = $now;
	}
	return $feed->{lastcheck} + $feed->{timeout};
}

sub feed_io_event_read {
	my $self = shift;
#	feedprint($self->{id} . " rdev " . (length $self->{io}->{buffer}));
	if($self->{io}->{state} == 1) {
		my $buf = '';
		my $readcnt = 8192;
		my $ret = $self->{io}->{conn}->read($buf, $readcnt) // 0;
		$self->{io}->{buffer} .= $buf;
		if($ret < $readcnt and $! != Errno::EAGAIN) {
			$self->{io}->{conn}->shutdown(SHUT_RD);
			feed_cleanup_conn($self);
			$self->{io}->{state} = 2;
			feed_parse_buffer($self);
		}
	}
	if($self->{io}->{conn} and not $self->{io}->{conn}->connected) {
		feed_cleanup_conn($self, 0);
		return;
	}
}

sub feed_io_event_write {
	my $self = shift;
	if(not $self->{io}->{conn}->connected) {
		feed_cleanup_conn();
		return;
	}
	if($self->{io}->{state} == 0) {
		my $query = $self->{uri}->path // '/';
		$query .= '?' . $self->{uri}->query if $self->{uri}->query;
		my $req = "GET " . $query . " HTTP/1.0\r\n" .
				"Host: " . $self->{uri}->host . "\r\n" .
				"User-Agent: Irssi feed reader " . $VERSION . "\r\n" .
				"Connection: close\r\n\r\n";
		$self->{io}->{conn}->send($req);
		Irssi::input_remove($self->{io}->{writetag}) if $self->{io}->{writetag};
		$self->{io}->{writetag} = 0;
		$self->{io}->{state} = 1;
		# $self->{io}->{conn}->shutdown(SHUT_WR); Appearantly sends a FIN,ACK, and e.g. Wikipedia interprets that as: Don't return the data...
	}
}

sub feed_cleanup_conn {
	my $feed = shift;
	my $delbuffer = shift;
	Irssi::input_remove($feed->{io}->{readtag}) if $feed->{io}->{readtag};
	$feed->{io}->{readtag} = 0;
	Irssi::input_remove($feed->{io}->{writetag}) if $feed->{io}->{writetag};
	$feed->{io}->{writetag} = 0;
	if($feed->{io}->{conn}) {
		$feed->{io}->{conn}->shutdown(SHUT_RDWR);
		if($feed->{io}->{conn}->connected) {
			$feed->{io}->{conn}->close;
		}
	}
	$feed->{io}->{conn} = 0;
	$feed->{io}->{buffer} = '' if $delbuffer;
	$feed->{io}->{state} = 0;
}

sub feed_parse_buffer {
	my $feed = shift;
	return unless($feed->{io}->{state} == 2);
	my $http = HTTP::Response->parse($feed->{io}->{buffer});
	return if not $http->is_success;
	my $httpcontent = $http->content;
	my $data = eval { $feed->{io}->{xml} = XML::Feed->parse(\$httpcontent) };
	if($data) {
		$feed->{name} = $data->title;
		$feed->{io}->{failed} = 0;
	} else {
		$feed->{active} = 0;
	}
	feed_cleanup_conn($feed, 1);
	check_feeds;
}

sub feed_get_news {
	my $self = shift;
	my $data = $self->{io}->{xml};
	return if(!$data);
	my @news = ();
	my $itemids = $self->{itemids};
	for my $item ($data->entries) {
		push(@news, $item) if(not exists $itemids->{$item->id});
		$itemids->{$item->id} = $self->{generation};
	}
	# forget about old entries
	foreach (keys %$itemids) {
		delete($itemids->{$_}) if($itemids->{$_} < $self->{generation});
	}
	if($self->{generation} == 0) {
		our $initial_skips;
		$initial_skips += $#news; # no +1 missing
		@news = ($news[ 0 ])
	}
	$self->{generation} += 1;
	$self->{io}->{xml} = 0;
	return @news;
}

sub feed_delete {
	my $self = shift;
	feed_cleanup_conn($self);
	our @feeds;
	@feeds = grep { $_ != $self } @feeds;
}

sub feed_stringrepr {
	my $feed = shift;
	return "#" .
	$feed->{id} . ": " .
	$feed->{name} . 
	(($feed->{name} ne $feed->{uri}) ? (" (" .$feed->{uri}. ")") : "") . 
	($feed->{active} ? " ":" in")."active, " . 
	$feed->{timeout} ."s";
}

sub feedprint {
	my ($msg) = @_;
		foreach my $window (Irssi::windows()) { #feeling a little bad here
		if ($window->{name} eq 'irssi-feed') {
			$window->print($msg);
			return;
		}
	}
	Irssi::print($msg);
}

Irssi::command_bind('feed', \&feedreader_cmd);
Irssi::settings_add_str('feedreader', 'feedlist', '');
our $initial_skips = 0;
our @feeds = ();
Irssi::timeout_add_once(500, \&initialize, 0);
