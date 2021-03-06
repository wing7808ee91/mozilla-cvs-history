#!/usr/bin/perl -w

package Doctor::File;

use strict;

use Cwd qw(getcwd chdir);

use Doctor qw(:DEFAULT %CONFIG);
use Doctor::Error;

use File::Temp qw(tempfile);

# doesn't import "diff" to prevent conflicts with our own
use Text::Diff ();

sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;

    my $spec = shift;

    my $self  = {};
    $self->{_content} = undef;
    $self->{_version} = undef;
    $self->{_spec} = undef;
    $self->{_tempdir} = undef;

    bless($self, $class);

    if (defined $spec) {
        $self->spec($spec)
          || ThrowUserError($self->{_error});
    }

    return $self;
}

# Note: because our property accessors are actually lvalue methods
# (i.e. $self->name is really just $self->name()), they don't simply
# interpolate in strings; instead Perl interpolates $self into something
# like Doctor::File=HASH(0xa1701cc) and then appends the property name
# (f.e. "->name") to it.
#
# To interpolate a property, you need to say: @{[$self->propname]}.
# For example if the value of the "name" property is "foo", then
# the string "$self->name @{[$self->propname]}" interpolates to:
# "Doctor::File=HASH(0xa1701cc)->name foo".

sub content {
    my $self = shift;
    if (!$self->{_content}) {
        $self->checkout();
        if (!$self->{_content}) {
            return undef;
        }
    }
    return $self->{_content};
}

sub version {
    my $self = shift;
    if (!$self->{_version}) {
        $self->checkout();
        if (!$self->{_version}) {
            return undef;
        }
    }
    return $self->{_version};
}

sub spec {
    my $self = shift;
    # The spec can only be set once.
    if (@_ && !$self->{_spec}) {
        $self->{_spec} = shift;

        # Make sure the spec doesn't contain a null byte to avoid attacks.
        if ($self->{_spec} =~ /\x00/) {
            $self->{_error} = "File specification contains null byte.";
            return;
        }

        # Canonicalize the spec:

        # URL -> Spec Conversion

        # Remove the absolute URI for files on the web site (if any)
        # from the beginning of the path.
        my $i = 0;
        my $match_found = 0;

        # If WEB_BASE_URI is defined, use it and ignore all WEB_BASE_URI_n, if any.
        # Else use WEB_BASE_URI_n, n = 1, 2, 3, ... .
        if ($CONFIG{'WEB_BASE_URI'}) {
            $self->is_valid_path;
            # We force the value so that we really ignore WEB_BASE_URI_n, even if
            # is_valid_path() returned false above.
            $match_found = 1;
        }

        while (!$match_found && defined $CONFIG{'WEB_BASE_URI_' . ++$i}) {
            $CONFIG{'WEB_BASE_URI'} = $CONFIG{'WEB_BASE_URI_' . $i};
            $CONFIG{'WEB_BASE_URI_PATTERN'} = $CONFIG{'WEB_BASE_URI_PATTERN_' . $i};
            $CONFIG{'WEB_BASE_PATH'} = $CONFIG{'WEB_BASE_PATH_' . $i};

            $match_found = $self->is_valid_path;
        }

        # At this point, WEB_BASE_URI must be defined. If not, stop here.
        ThrowCodeError("No WEB_BASE_URI parameter defined.", "Configuration Error")
            unless $CONFIG{'WEB_BASE_URI'};

        # If the given URI doesn't match anything and there are more than
        # one website managed by this installation, we cannot go further
        # as we have no idea which website the user is talking about.
        if (!$match_found && $i > 2) {
            $self->{_error} = "Invalid URI: " . $self->{_spec} . " is ambiguous";
            return;
        }

        # Entire Spec Issues

        # Collapse multiple consecutive slashes (i.e. dir//file.txt) into one.
        $self->{_spec} =~ s:/{2,}:/:;

        # Beginning of Spec Issues

        # Remove a preceding slash.
        $self->{_spec} =~ s:^/::;

        # Add the base path of the file in the CVS repository if necessary.
        # (i.e. if the user entered a URL or a path based on the URL).
        if ($self->{_spec} !~ /^\Q$CONFIG{WEB_BASE_PATH}\E/) {
            $self->{_spec} = $CONFIG{WEB_BASE_PATH} . $self->{_spec};
        }

        # End of Spec Issues

        # If the filename (the last name in the path) contains no period,
        # it is probably a directory, so add a slash.
        if ($self->{_spec} =~ m:^[^\./]+$: || $self->{_spec} =~ m:/[^\./]+$:) { $self->{_spec} .= "/" }

        # If the file ends with a forward slash, it is a directory,
        # so add the name of the default file.
        if ($self->{_spec} =~ m:/$:) { $self->{_spec} .= "index.html" }
    }
    return $self->{_spec};
}

sub is_valid_path {
    my $self = shift;

    if ($CONFIG{'WEB_BASE_URI_PATTERN'}) {
        if ($self->{_spec} =~ /^$CONFIG{WEB_BASE_URI_PATTERN}/i) {
            $self->{_spec} =~ s/^$CONFIG{WEB_BASE_URI_PATTERN}//i;
            return 1;
        }
    }
    else {
        if ($self->{_spec} =~ /^\Q$CONFIG{WEB_BASE_URI}\E/i) {
            $self->{_spec} =~ s/^\Q$CONFIG{WEB_BASE_URI}\E//i;
            return 1;
        }
    }
    # If we come here, then the URI doesn't match a known URL.
    # Maybe it's a URI relative to the CVS repository.
    return 1 if ($self->{_spec} =~ /^\Q$CONFIG{WEB_BASE_PATH}\E/);

    # So we definitely don't match anything.
    return 0;
}

sub tempdir {
    my $self = shift;
    $self->{_tempdir} ||=
        File::Temp->tempdir("doctor-XXXXXXXX", TMPDIR => 1, CLEANUP => 1);
    return $self->{_tempdir};
}

sub line_endings {
    my $self = shift;
    if      (!$self->content)               { return undef }
    elsif   ($self->content =~ /\r\n/s)     { return "windows" }
    elsif   ($self->content =~ /\r[^\n]/s)  { return "mac" }
    else                                    { return "unix" }
}

sub linebreak {
    my $self = shift;
    if      (!$self->content)               { return undef; }
    elsif   ($self->content =~ /\r\n/s)     { return "\r\n" }
    elsif   ($self->content =~ /\r[^\n]/s)  { return "\r" }
    else                                    { return "\n" }
}

sub url {
    my $self = shift;
        # Construct a URL to the file if possible.
    my $spec = $self->spec;
    if ($spec =~ s/^\Q$CONFIG{WEB_BASE_PATH}\E(.*)$/$1/i) {
        return $CONFIG{WEB_BASE_URI} . $spec;
    }
    else {
        return undef;
    }
}

sub name {
    my $self = shift;
    return $self->_name_or_path("name");
}

sub path {
    my $self = shift;
    return $self->_name_or_path("path");
}

sub _name_or_path {
    my $self = shift;
    my $type = shift;
    $self->spec
      || return undef;
    $self->spec =~ /^(.*[\/\\])?([^\/\\]+)$/;
    return ($type eq "path" ? $1 : ($type eq "name" ? $2 : undef));
}

sub relative_spec {
    # Returns the part of the spec which appears in the URL after the server name.
    my $self = shift;
    $self->spec
      || return undef;
    $self->spec =~ /^\Q$CONFIG{WEB_BASE_PATH}\E(.*)$/;
    return $1;
}

sub add {
    my $self = shift;
    my $content = shift;

    # Convert line breaks to UNIX EOL for new files, by default.
    $content =~ s/\r\n|\r/\n/g;

    my $olddir = getcwd();
    chdir $self->tempdir;

    # Write the content to a file.
    open(FILE, ">", $self->name) or die "Couldn't create @{[$self->name]}: $!";
    print FILE $content;
    close(FILE);

    # Create a fake CVS directory that makes the temporary directory look like
    # a local working copy of the directory in the repository where this file
    # will be created.  This way we just have to commit the file to create it;
    # we avoid having to first check out the directory and then add the file.  
    mkdir("CVS") or die("Couldn't create CVS directory: $!");
    chdir("CVS");
  
    # Make the Entries file and add an entry for the new file.
    open(FILE, ">Entries") or die "Couldn't create CVS/Entries file: $!";
    print FILE "/@{[$self->name]}/0/Initial @{[$self->name]}//\nD\n";
    close(FILE);
    
    # Make the Repository file, which contains the path to the directory.
    open(FILE, ">Repository") or die "couldn't create CVS/Repository file: $!";
    print FILE "@{[$self->path]}\n";
    close(FILE);
    
    # Note that we don't have to create a Root file with information about
    # the repository (authentication type, server address, root path, etc.)
    # since we add that information to the command line.
    
    chdir $olddir;
}

sub patch {
    my $self = shift;
    my $newcontent = shift;

    # Convert line breaks to whatever the file in CVS uses.
    my $linebreak = $self->linebreak;
    $newcontent =~ s/\r\n|\r|\n/$linebreak/g;

    my $olddir = getcwd();
    chdir $self->tempdir;
    -e $self->spec or $self->checkout();
    open(FILE, ">", $self->spec) or die "couldn't open @{[$self->spec]}: $!";
    print FILE $newcontent;
    close(FILE);
    chdir $olddir;
}

sub checkout {
    my $self = shift;

    my @args = ("-d", 
                ":pserver:$CONFIG{READ_CVS_USERNAME}:$CONFIG{READ_CVS_PASSWORD}\@$CONFIG{READ_CVS_SERVER}", 
                "checkout", 
                $self->spec);
  
    my $olddir = getcwd();
    chdir $self->tempdir;

    # Check out the file from the repository, capturing the output
    # of the command and any error messages.
    my ($rv, $output, $errors) = Doctor::system_capture("cvs", @args);

    # File was previously added but has since been deleted (and is now in the Attic)
    if ($rv == 0 && $errors =~ /not \(any longer\) pertinent/) {
        $self->{_version} = "new";
    }
    # Extract the content and version.
    elsif ($rv == 0) {
        # Extract the version from the CVS/Entries file.
        open(FILE, "<", $self->path . "CVS/Entries")
          or die "Can't open @{[$self->spec]}/CVS/Entries: $!";
        my $entry = <FILE>; # just the first line, which should be all there is
        close(FILE);
        $entry =~ m:^/[^/]*/([^/]*)/:;
        $self->{_version} = $1;

        # Extract the content from the file.  In a block to localize $/
        {
            local $/ = undef;
            open(FILE, "<", $self->spec)
              or die "Can't open @{[$self->spec]}: $!";
            $self->{_content} = <FILE>;
            close(FILE);
        }
    }
    # File not found; treat it as new
    elsif ($errors =~ /cannot find/) {
        $self->{_version} = "new";
    }

    chdir $olddir;

    return ($rv, $output, $errors);
}

sub commit {
    # Commits changes to the repository.  Requires the file to already be
    # checked out, patched, and sitting in the temporary directory waiting
    # to be committed.  Dies otherwise.

    my $self = shift;
    my ($username, $password, $comment) = @_;

    # New files get added to the top-level of the temporary directory
    # rather than the appropriate subdirectory (we just hack CVS/Repository
    # to make it look like the appropriate subdirectory; see the add() function
    # for the details), so if the file is new we set the spec to the name
    # of the file instead of its full spec.
    my $spec = $self->version eq "new" ? $self->name : $self->spec;

    my $cvsroot = ":pserver:$username";
    # Only include the password if one is given.
    if ($password) {
        $cvsroot .= ":$password";
    }
    $cvsroot .= "\@$CONFIG{WRITE_CVS_SERVER}";

    my @args = ("-d", $cvsroot, "commit", "-m", $comment, $spec);

    # Check the file into the repository and capture the results.
    my $olddir = getcwd();
    chdir $self->tempdir;
    -e $spec or die "couldn't find $spec: $!";
    my ($rv, $output, $errors) = Doctor::system_capture("cvs", @args);
    chdir $olddir;
  
    return ($rv, $output, $errors);
}

sub diff {
    my $self = shift;
    my $revision = shift;
    if (!$revision) { die("no revision to diff") }

    # Convert line breaks to whatever the file in CVS uses.
    my $linebreak = $self->linebreak;
    $revision =~ s/\r\n|\r|\n/$linebreak/g;

    return Text::Diff::diff(\$self->content, \$revision,
                            {FILENAME_A => $self->spec, FILENAME_B => $self->spec});
}

1;  # so the require or use succeeds
