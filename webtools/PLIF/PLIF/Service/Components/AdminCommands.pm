# -*- Mode: perl; tab-width: 4; indent-tabs-mode: nil; -*-
#
# This file is MPL/GPL dual-licensed under the following terms:
# 
# The contents of this file are subject to the Mozilla Public License
# Version 1.1 (the "License"); you may not use this file except in
# compliance with the License. You may obtain a copy of the License at
# http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS IS"
# basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
# the License for the specific language governing rights and
# limitations under the License.
#
# The Original Code is PLIF 1.0.
# The Initial Developer of the Original Code is Ian Hickson.
#
# Alternatively, the contents of this file may be used under the terms
# of the GNU General Public License Version 2 or later (the "GPL"), in
# which case the provisions of the GPL are applicable instead of those
# above. If you wish to allow use of your version of this file only
# under the terms of the GPL and not to allow others to use your
# version of this file under the MPL, indicate your decision by
# deleting the provisions above and replace them with the notice and
# other provisions required by the GPL. If you do not delete the
# provisions above, a recipient may use your version of this file
# under either the MPL or the GPL.

package PLIF::Service::Components::AdminCommands;
use strict;
use vars qw(@ISA);
use PLIF::Service;
@ISA = qw(PLIF::Service);
1;

# Any application that uses PLIF::Service::AdminCommands must also
# implement "setupFailed($result)" and "setupSucceeded()" in any
# output services that might get called in a Setup context, as well as
# default string data sources for any protocols that might be used in
# a Setup context that use the Generic output module other than
# 'stdout' which is supported by this module itself.

sub provides {
    my $class = shift;
    my($service) = @_;
    return ($service eq 'input.verify' or 
            $service eq 'component.adminCommands' or 
            $service eq 'dispatcher.output.generic' or 
            $service eq 'dispatcher.output' or 
            $service eq 'dataSource.strings.default' or
            $class->SUPER::provides($service));
}

__DATA__

sub objectProvides {
    my $self = shift;
    my($service) = @_;
    return ($service eq 'dispatcher.commands' or 
            $self->SUPER::objectProvides($service));
}

# input.verify
sub verifyInput {
    my $self = shift;
    my($app) = @_;
    if ($app->input->isa('PLIF::Input::CommandLine')) {
        $app->addObject($self);
    }
    return;
}

# dispatcher.commands
sub cmdSetup {
    my $self = shift;
    my($app) = @_;
    # call all the setup handlers until one fails:
    # the setupX methods can call $app->output->setupProgress('component.subcomponent');
    $app->getPipingServiceList('setup.events.start')->setupStarting($app);
    $app->output->setupProgress('setup');
    my @result = $app->getSelectingServiceList('setup.configure')->setupConfigure($app);
    if (not @result) {
        @result = $app->getSelectingServiceList('setup.install')->setupInstall($app);
    }
    # report on the result
    if (@result) {
        # if we failed, first report that then signal that
        # configuration has ended
        $self->dump(9, "Failed to setup because argument '$result[0]' was missing.");
        $app->output->setupFailed($result[0]);
        $app->getPipingServiceList('setup.events.end')->setupEnding($app);
    } else {
        # if it did not fail, then signal that configuration ended and
        # then use our swanky new setup to tell the user it worked.
        $app->getPipingServiceList('setup.events.end')->setupEnding($app);
        $app->output->setupSucceeded();
    }
}

# dispatcher.output.generic
sub outputSetupSucceeded {
    my $self = shift;
    my($app, $output) = @_;
    $output->output('setup', {
        'failed' => 0,
    });
}

# dispatcher.output.generic as well
sub outputSetupFailed {
    my $self = shift;
    my($app, $output, $result) = @_;
    $output->output('setup', {
        'failed' => 1,
        'result' => $result,
    });
}

# dispatcher.output.generic as well
sub outputSetupProgress {
    my $self = shift;
    my($app, $output, $component) = @_;
    $output->output('setup.progress', {
        'component' => $component,
    });
}

# dispatcher.output
sub strings {
    return (
            'setup' => 'The message given at the end of the setup command (only required for stdout, since it is the only way to trigger setup); failed is a boolean, result is the error message if any',
            'setup.progress' => 'Progress messages given during setup (only required for stdout); component is a dotted hierarchical string giving progressively more detail about what is being set up. e.g., \'database\', \'database.default.settings\', \'database.default.settings.connection.port\'. If outputters are interpreting component then any trailing unknown levels of detail should be ignored.',
            );
}

# dataSource.strings.default
sub getDefaultString {
    my $self = shift;
    my($args) = @_;
    if ($args->{'protocol'} eq 'stdout') {
        if ($args->{'name'} eq 'setup') {
            $args->{'type'} = 'COSES';
            $args->{'version'} = 1;
            $args->{'string'} = '<text xmlns="http://bugzilla.mozilla.org/coses"><if lvalue="(failed)" condition="=" rvalue="1">Can\'t continue: argument <text value="(result)"/> is missing.</if><else>Succeeded!</else><br/></text>';
            return 1;
        } elsif ($string eq 'setup.progress') {
            $args->{'type'} = 'COSES';
            $args->{'version'} = 1;
            $args->{'string'} = '<text xmlns="http://bugzilla.mozilla.org/coses">Setup: <text value="(component)"/>...<br/></text>';
            return 1;
        }
    }
    return;
}

