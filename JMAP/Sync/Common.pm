#!/usr/bin/perl -c

use strict;
use warnings;

package JMAP::Sync::Common;

use Mail::IMAPTalk;
use JSON::XS qw(encode_json decode_json);
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTPS;
use Net::CalDAVTalk;
use Net::CardDAVTalk;

my %KNOWN_SPECIALS = map { lc $_ => 1 } qw(\\HasChildren \\HasNoChildren \\NoSelect \\NoInferiors);

sub new {
  my $Class = shift;
  my $auth = shift;
  return bless { auth => $auth }, ref($Class) || $Class;
}

sub DESTROY {
  my $Self = shift;
  if ($Self->{imap}) {
    $Self->{imap}->logout();
  }
}

sub get_calendars {
  my $Self = shift;
  my $talk = $Self->connect_calendars();

  my $data = $talk->GetCalendars();

  return $data;
}

sub get_events {
  my $Self = shift;
  my $Args = shift;
  my $talk = $Self->connect_calendars();

  my $data = $talk->GetEvents($Args->{href}, Full => 1);

  my %res;
  foreach my $item (@$data) {
    $res{$item->{id}} = $item->{_raw};
  }

  return \%res;
}

sub get_abooks {
  my $Self = shift;
  my $talk = $Self->connect_contacts();

  my $data = $talk->GetAddressBooks();

  return $data;
}

sub get_contacts {
  my $Self = shift;
  my $Args = shift;
  my $talk = $Self->connect_contacts();

  my $data = $talk->GetContacts($Args->{path});

  my %res;
  foreach my $item (@$data) {
    $res{$item->{CPath}} = $item->{_raw};
  }

  return \%res;
}

# read folder list from the server
sub folders {
  my $Self = shift;
  $Self->connect_imap();
  return $Self->{folders};
}

sub capability {
  my $Self = shift;
  my $imap = $Self->connect_imap();
  return $imap->capability();
}

sub labels {
  my $Self = shift;
  $Self->connect_imap();
  return $Self->{labels};
}

sub imap_status {
  my $Self = shift;
  my $folders = shift;

  my $imap = $Self->connect_imap();

  my @fields = qw(uidvalidity uidnext messages);
  push @fields, "highestmodseq" if $imap->capability->{condstore};
  my $data = $imap->multistatus("(@fields)", @$folders);

  return $data;
}

# no newname == delete
sub imap_update {
  my $Self = shift;
  my $imapname = shift;
  my $olduidvalidity = shift || 0;
  my $uids = shift;
  my $isAdd = shift;
  my $flags = shift;

  my $imap = $Self->connect_imap();

  my $r = $imap->select($imapname);
  die "SELECT FAILED $imapname" unless $r;

  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;

  my %res = (
    imapname => $imapname,
    olduidvalidity => $olduidvalidity,
    newuidvalidity => $uidvalidity,
  );

  if ($olduidvalidity != $uidvalidity) {
    return \%res;
  }

  $imap->store($uids, $isAdd ? "+flags" : "-flags", "(@$flags)");

  $res{updated} = $uids;

  return \%res;
}

sub imap_fill {
  my $Self = shift;
  my $imapname = shift;
  my $olduidvalidity = shift || 0;
  my $uids = shift;

  my $imap = $Self->connect_imap();

  my $r = $imap->examine($imapname);
  die "EXAMINE FAILED $imapname" unless $r;

  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;

  my %res = (
    imapname => $imapname,
    olduidvalidity => $olduidvalidity,
    newuidvalidity => $uidvalidity,
  );

  if ($olduidvalidity != $uidvalidity) {
    return \%res;
  }

  my $data = $imap->fetch($uids, "rfc822");

  my %ids;
  foreach my $uid (keys %$data) {
    $ids{$uid} = $data->{$uid}{rfc822};
  }
  $res{data} = \%ids;
  return \%res;
}

sub imap_count {
  my $Self = shift;
  my $imapname = shift;
  my $olduidvalidity = shift || 0;
  my $uids = shift;

  my $imap = $Self->connect_imap();

  my $r = $imap->examine($imapname);
  die "EXAMINE FAILED $imapname" unless $r;

  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;

  my %res = (
    imapname => $imapname,
    olduidvalidity => $olduidvalidity,
    newuidvalidity => $uidvalidity,
  );

  if ($olduidvalidity != $uidvalidity) {
    return \%res;
  }

  my $data = $imap->fetch($uids, "UID");

  $res{data} = [sort { $a <=> $b } keys %$data];
  return \%res;
}

# no newname == delete
sub imap_move {
  my $Self = shift;
  my $imapname = shift;
  my $olduidvalidity = shift || 0;
  my $uids = shift;
  my $newname = shift;

  my $imap = $Self->connect_imap();

  my $r = $imap->select($imapname);
  die "SELECT FAILED $imapname" unless $r;

  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;

  my %res = (
    imapname => $imapname,
    newname => $newname,
    olduidvalidity => $olduidvalidity,
    newuidvalidity => $uidvalidity,
  );

  if ($olduidvalidity != $uidvalidity) {
    return \%res;
  }

  if ($newname) {
    # move
    if ($imap->capability->{move}) {
      my $res = $imap->move($uids, $newname);
      unless ($res) {
        $res{notMoved} = $uids;
        return \%res;
      }
    }
    else {
      my $res = $imap->copy($uids, $newname);
      unless ($res) {
        $res{notMoved} = $uids;
        return \%res;
      }
      $imap->store($uids, "+flags", "(\\seen \\deleted)");
      $imap->uidexpunge($uids);
    }
  }
  else {
    $imap->store($uids, "+flags", "(\\seen \\deleted)");
    $imap->uidexpunge($uids);
  }

  $res{moved} = $uids;

  return \%res;
}

sub imap_fetch {
  my $Self = shift;
  my $imapname = shift;
  my $state = shift || {};
  my $fetch = shift || {};

  my $imap = $Self->connect_imap();

  my $r = $imap->examine($imapname);
  die "EXAMINE FAILED $imapname" unless $r;

  my $uidvalidity = $imap->get_response_code('uidvalidity') + 0;
  my $uidnext = $imap->get_response_code('uidnext') + 0;
  my $highestmodseq = $imap->get_response_code('highestmodseq') || 0;
  my $exists = $imap->get_response_code('exists') || 0;

  my %res = (
    imapname => $imapname,
    oldstate => $state,
    newstate => {
      uidvalidity => $uidvalidity + 0,
      uidnext => $uidnext + 0,
      highestmodseq => $highestmodseq + 0,
      exists => $exists + 0,
    },
  );

  if (($state->{uidvalidity} || 0) != $uidvalidity) {
    warn "UIDVALID $state->{uidvalidity} $uidvalidity\n";
    $res{uidfail} = 1;
    return \%res;
  }

  foreach my $key (keys %$fetch) {
    my $item = $fetch->{$key};
    my $from = $item->[0];
    my $to = $item->[1];
    $to = $uidnext - 1 if $to eq '*';
    next if $from > $to;
    my @flags = qw(uid flags);
    push @flags, @{$item->[2]} if $item->[2];
    next if ($highestmodseq and $item->[3] and $item->[3] == $highestmodseq);
    my @extra;
    push @extra, "(changedsince $item->[3])" if $item->[3];
    my $data = $imap->fetch("$from:$to", "(@flags)", @extra) || {};
    $res{$key} = [$item, $data];
  }

  return \%res;
}

sub imap_append {
  my $Self = shift;
  my $imapname = shift;
  my $flags = shift;
  my $internaldate = shift;
  my $rfc822 = shift;

  my $imap = $Self->connect_imap();

  my $r = $imap->append($imapname, $flags, $internaldate, ['Literal', $rfc822]);
  die "APPEND FAILED $r" unless lc($r) eq 'ok';

  my $uid = $imap->get_response_code('appenduid');

  # XXX - fetch the x-gm-msgid or envelope from the server so we know the
  # the ID that the server gave this message

  return ['append', $imapname, $uid];
}

1;