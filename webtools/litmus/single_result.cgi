#!/usr/bin/perl -w
# -*- mode: cperl; c-basic-offset: 8; indent-tabs-mode: nil; -*-

# ***** BEGIN LICENSE BLOCK *****
# Version: MPL 1.1
#
# The contents of this file are subject to the Mozilla Public License Version
# 1.1 (the "License"); you may not use this file except in compliance with
# the License. You may obtain a copy of the License at
# http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS IS" basis,
# WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
# for the specific language governing rights and limitations under the
# License.
#
# The Original Code is Litmus.
#
# The Initial Developer of the Original Code is
# the Mozilla Corporation.
# Portions created by the Initial Developer are Copyright (C) 2006
# the Initial Developer. All Rights Reserved.
#
# Contributor(s):
#   Chris Cooper <ccooper@deadsquid.com>
#   Zach Lipton <zach@zachlipton.com>
#
# ***** END LICENSE BLOCK *****

use strict;

use Litmus;
use Litmus::Auth;
use Litmus::Error;
use Litmus::DB::Testresult;
use Litmus::DB::Resultbug;

use CGI;
use Date::Manip;

Litmus->init();
my $c = Litmus->cgi(); 
print $c->header();

if ($c->param && $c->param('id')) {
  
  my $title = 'Test Result #' . $c->param('id') . ' - Details';
  my $vars = {
              title => $title,
             };
  
  my $result = Litmus::DB::Testresult->retrieve($c->param('id'));
  
  if (!$result) {
    internalError("There is no test result corresponding to id#: " . $c->param('id') . ".");
    exit 1;
  }

  if ($result->is_automated_result) {
    $vars->{'title'} = "Automated " . $title;
  }
  
  my $time = &Date::Manip::UnixDate("now","%q");
  my $cookie =  Litmus::Auth::getCookie();
  my $user;
  if ($cookie) {
    $user = $cookie->user_id();
    
    if ($user and 
        $c->param('new_bugs') and
        $c->param('new_bugs') ne '') {
      
      my $new_bug_string = $c->param('new_bugs');
      $new_bug_string =~ s/[^0-9,]//g;
      my @new_bugs = split(/,/,$new_bug_string);
      foreach my $new_bug (@new_bugs) {
        next if ($new_bug eq '0');
        if (!Litmus::DB::Resultbug->search(test_result_id =>$c->param('id'),
                                           bug_id => $new_bug)) {
          my $bug = Litmus::DB::Resultbug->create({
                                                   test_result => $result,
                                                   last_updated => $time,
                                                   submission_time => $time,
                                                   user => $user,
                                                   bug_id => $new_bug,
                                                  });
        }
      }
    } 
    
    if ($user and
        $c->param('new_comment') and
        $c->param('new_comment') ne '') {
      my $comment = Litmus::DB::Comment->create({
                                                 test_result => $result,
                                                 last_updated => $time,
                                                 submission_time => $time,
                                                 user => $user,
                                                 comment => $c->param('new_comment'),
                                                });    
    }
    
    if (Litmus::Auth::istrusted($cookie) and
        $c->param('vet_result')) {
      if ($c->param('valid')) {
        $result->valid(1);
      } else {
        $result->valid(0);
      }
      $result->vetted(1);
      $result->vetted_by_user($user);
      $result->validated_by_user($user);
      $result->vetted_timestamp($time);
      $result->validated_timestamp($time);
      $result->last_updated($time);
      $result->update;
    }
    if ((Litmus::Auth::istrusted($cookie) or
         $cookie == $result->user_id) and 
        $c->param('change_result_status') and
        $c->param('result_status')) {
      # Ignore submission if it doesn't actually change the status.
      if ($c->param('result_status') ne $result->result_status_id->class_name){
        my ($new_status) = Litmus::DB::ResultStatus->search(class_name => $c->param('result_status'));
        if ($new_status) {
          $result->result_status($new_status);
          $result->last_updated($time);
          $result->update;
        }
      }
    }
    
  }

  $vars->{"result"} = $result;
  
  if ($cookie) {
    $vars->{"defaultemail"} = $cookie;
    $vars->{"show_admin"} = $cookie->is_admin();
  }
  
  Litmus->template()->process("reporting/single_result.tmpl", $vars) || 
    internalError("Error loading template.");
  
} else {
  internalError("You must provide a test result id#.");
  exit 1;
}

exit 0;
