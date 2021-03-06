# This is a Perl library for storing the data from the iPhone interface of
# Heatmiser's range of Wi-Fi enabled thermostats in a MySQL database.
#
# Before this is used for the first time it is necessary to create a database
# called 'heatmiser' and a local user called 'heatmiser' with suitable
# access permissions. This can be done with:
#   mysql -u root -p
#   CREATE DATABASE heatmiser;
#   CREATE USER 'heatmiser'@'localhost';
#   GRANT ALL ON heatmiser.* TO 'heatmiser'@'localhost';

# Copyright © 2011, 2012, 2013 Alexander Thoukydides

# This file is part of the Heatmiser Wi-Fi project.
# <http://code.google.com/p/heatmiser-wifi/>
#
# Heatmiser Wi-Fi is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version.
#
# Heatmiser Wi-Fi is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License
# along with Heatmiser Wi-Fi. If not, see <http://www.gnu.org/licenses/>.


package heatmiser_db;

# Catch errors quickly
use strict;
use warnings;

# Useful libraries
use DBI;


# Default configuration options
my %default_options =
(
    dbsource   => 'dbi:mysql:heatmiser',
    dbuser     => 'heatmiser',
    dbpassword => '',
    dateformat => 'mysql', # or 'javascript' for milliseconds since 1 Jan 1970
    host       => []
);


# BASIC OBJECT HANDLING

# Constructor
sub new
{
    my ($class, %options) = @_;
    my $self = {};
    bless $self, $class;
    $self->initialise(%options);
    return $self;
}

# Configure and connect to the I/O server
sub initialise
{
    my ($self, %options) = @_;

    # Use defaults unless appropriate options specified
    my ($key, $default);
    while (($key, $default) = each %default_options)
    {
        $self->{$key} = defined $options{$key} ? $options{$key} : $default;
    }

    # Connect to the database
    my $db = db($self); # ($self has not been blessed yet)

    # Create any missing database tables
    $db->do('CREATE TABLE IF NOT EXISTS settings (thermostat varchar(255), name VARCHAR(20), value VARCHAR(255), PRIMARY KEY (thermostat, name))');
    $db->do('CREATE TABLE IF NOT EXISTS comfort (thermostat varchar(255), day TINYINT(1), entry TINYINT(1), time TIME, target TINYINT(2), PRIMARY KEY (thermostat, day, entry))');
    $db->do('CREATE TABLE IF NOT EXISTS timer (thermostat varchar(255), day TINYINT(1), entry TINYINT(1), timeon TIME, timeoff TIME, PRIMARY KEY (thermostat, day, entry))');
    $db->do('CREATE TABLE IF NOT EXISTS temperatures (thermostat varchar(255), time DATETIME, air DECIMAL(3,1), target TINYINT(2), comfort TINYINT(2), PRIMARY KEY (thermostat, time))');
    $db->do('CREATE TABLE IF NOT EXISTS events (thermostat varchar(255), time DATETIME NOT NULL, class VARCHAR(20) NOT NULL, state VARCHAR(20), temperature TINYINT(2))');
    $db->do('CREATE TABLE IF NOT EXISTS weather (time DATETIME, external DECIMAL(3,1), PRIMARY KEY (time))');

    # Upgrade all of the thermostat tables to support multiple thermostats
    foreach my $table (qw(settings comfort timer temperatures events))
    {
        # List the table's current columns
        my $fields = $db->selectall_hashref('SHOW COLUMNS FROM ' . $table, 'Field');

        # Add a 'thermostat' column if it does not already exist
        unless (exists $fields->{thermostat})
        {
            # Need a single thermostat configured to use for existing rows
            die "A single thermostat is required for database upgrade\n" unless scalar @{$self->{host}} == 1;
            my $thermostat = $self->{host}->[0];

            # Prepare the SQL statement to insert the new column
            my $sql = 'ALTER TABLE ' . $table . " ADD thermostat varchar(255) default '" . $thermostat . "' FIRST";
            my @primary = grep { $fields->{$_}->{Key} eq 'PRI' } keys %$fields;
            $sql .= ', DROP PRIMARY KEY, ADD PRIMARY KEY (' . join(',', 'thermostat', @primary) . ')' if scalar @primary;

            # Add the missing table column
            warn "Upgrading database table '$table'\n";
            $db->do($sql);
            $db->do('ALTER TABLE ' . $table . ' ALTER thermostat DROP DEFAULT');
        }
    }
}

# Database connection
sub db
{
    my ($self) = @_;

    # Connect to the database
    my $db = DBI->connect_cached($self->{dbsource},
                                 $self->{dbuser}, $self->{dbpassword},
                                 {
                                     # Die if an error occurs
                                     PrintError => 0,
                                     RaiseError => 1,
                                     # Transactions are explicit where used
                                     AutoCommit => 1
                                 })
        or die "Cannot connect to database: $DBI::errstr\n";

    # Prevent timezone conversions for non-MySQL date formats
    $db->do("SET time_zone='+00:00'");

    # Return the handle
    return $db;
}

# Destructor
sub DESTROY
{
    my ($self) = @_;
}


# DATABASE TABLE UPDATE

# Add an entry to an arbitrary table
sub x_insert
{
    my ($self, $thermostat, $table, %entry) = @_;

    # Connect to the database
    my $db = $self->db();

    # Add the thermostat to the entry
    $entry{thermostat} = $thermostat if defined $thermostat;

    # Prepare the SQL statement to insert a new table entry
    my @fields = sort keys %entry; # (consistent order to allow cacheing)
    my @values = @entry{@fields};
    my $sql = sprintf 'INSERT INTO %s (%s) VALUES (%s)',
                      $table, join(',', @fields), join(',', ('?') x @fields);
    my $insert = $db->prepare_cached($sql);

    # Insert this entry into the database
    $insert->execute(@values);
}

# Add a log entry
sub log_insert
{
    my ($self, $thermostat, %log) = @_;

    # Insert a new log entry into the database
    $self->x_insert($thermostat, 'temperatures', %log);
}

# Add an event entry
sub event_insert
{
    my ($self, $thermostat, %event) = @_;

    # Insert a new event entry into the database
    $self->x_insert($thermostat, 'events', %event);
}

# Add a weather entry
sub weather_insert
{
    my ($self, %weather) = @_;

    # Insert a new weather entry into the database
    $self->x_insert(undef, 'weather', %weather);
}

# Replace the thermostat settings
sub settings_update
{
    my ($self, $thermostat, %settings) = @_;

    # Connect to the database
    my $db = $self->db();

    # Perform the update as a single transaction
    eval
    {
        # Prepare the SQL statements to modify settings table entries
        my $replace = $db->prepare_cached('REPLACE settings (thermostat, name, value) VALUES (?,?,?)');
        my $names = $db->prepare_cached("SELECT name FROM settings WHERE (thermostat='" . $thermostat . "')");
        my $delete = $db->prepare_cached('DELETE FROM settings WHERE (thermostat=?) AND (name=?)');

        # Update all specified settings entries
        $db->{AutoCommit} = 0;
        while (my ($name, $value) = each %settings)
        {
            $replace->execute($thermostat, $name, $value);
        }

        # Delete any settings for which values were not specified
        $names->execute();
        my @names = map { $_->[0] } @{$names->fetchall_arrayref()};
        foreach my $name (grep { not exists $settings{$_} } @names)
        {
            $delete->execute($thermostat, $name);
        }

        # Commit the changes
        $db->{AutoCommit} = 1;
    };
    if ($@)
    {
        # Rollback the incomplete changes
        my $error = $@;
        eval { $db->rollback };
        $db->{AutoCommit} = 1;
        die "Settings update transaction aborted: $error\n";
    }
}

# Replace the comfort levels
sub comfort_update
{
    my ($self, $thermostat, $comfort) = @_;

    # Connect to the database
    my $db = $self->db();

    # Perform the update as a single transaction
    eval
    {
        # Prepare the SQL statements to modify comfort table entries
        my $replace = $db->prepare_cached('REPLACE comfort (thermostat, day, entry, time, target) VALUES (?,?,?,?,?)');
        my $delete = $db->prepare_cached('DELETE FROM comfort WHERE (thermostat=?) AND (day=?) AND (entry=?)');

        # Update all possible table entries (7 days, 4 entries per day)
        $db->{AutoCommit} = 0;
        foreach my $day (0 .. 6)
        {
            foreach my $entry (0 .. 3)
            {
                my $detail = $comfort->[$day]->[$entry];
                if ($detail)
                {
                    $replace->execute($thermostat, $day, $entry, $detail->{time}, $detail->{target});
                }
                else
                {
                    $delete->execute($thermostat, $day, $entry);
                }
            }
        }

        # Commit the changes
        $db->{AutoCommit} = 1;
    };
    if ($@)
    {
        # Rollback the incomplete changes
        my $error = $@;
        eval { $db->rollback };
        $db->{AutoCommit} = 1;
        die "Comfort levels update transaction aborted: $error\n";
    }
}

# Replace the timer program
sub timer_update
{
    my ($self, $thermostat, $timer) = @_;

    # Connect to the database
    my $db = $self->db();

    # Perform the update as a single transaction
    eval
    {
        # Prepare the SQL statements to modify timer table entries
        my $replace = $db->prepare_cached('REPLACE timer (thermostat, day, entry, timeon, timeoff) VALUES (?,?,?,?,?)');
        my $delete = $db->prepare_cached('DELETE FROM timer WHERE (thermostat=?) AND (day=?) AND (entry=?)');

        # Update all possible table entries (7 days, 4 entries per day)
        $db->{AutoCommit} = 0;
        foreach my $day (0 .. 6)
        {
            foreach my $entry (0 .. 3)
            {
                my $detail = $timer->[$day]->[$entry];
                if ($detail)
                {
                    $replace->execute($thermostat, $day, $entry, $detail->{on}, $detail->{off});
                }
                else
                {
                    $delete->execute($thermostat, $day, $entry);
                }
            }
        }

        # Commit the changes
        $db->{AutoCommit} = 1;
    };
    if ($@)
    {
        # Rollback the incomplete changes
        my $error = $@;
        eval { $db->rollback };
        $db->{AutoCommit} = 1;
        die "Timer program update transaction aborted: $error\n";
    }
}


# DATABASE TABLE QUERIES

# HERE - Add options to retrieve weekdate/weekend or mon/tue/wed/...

# Retrieve specified log entries
sub log_retrieve
{
    my ($self, $thermostat, $fields, $where, $groupby) = @_;

    # Connect to the database
    my $db = $self->db();

    # Construct columns to retrieve
    my @fields = @$fields;
    foreach my $field (@fields)
    {
        # Aggregated data
        my $op;
        $op = $field =~ /^(target|comfort)$/ ? 'MAX' : 'AVG' if $groupby;
        $op = uc $1 if $field =~ s/^(min|max|avg|count|date)_//i;
        $field = "$op($field)" if defined $op;

        # Convert dates to the selected format
        $field = $self->date_from_mysql($field) if $field =~ /\btime\b/;
    }

    # Convert a range specification into a WHERE clause
    $where = $self->where_range($where) if ref $where eq 'HASH';

    # Prepare the SQL statement to retrieve each log entry
    my $sql = 'SELECT ' . join(',', @fields) . ' FROM temperatures';
    $sql .= ' WHERE' if defined $thermostat or defined $where;
    $sql .= " (thermostat='" . $thermostat . "')" if defined $thermostat;
    $sql .= ' AND' if defined $thermostat and defined $where;
    $sql .= ' (' . $where . ')' if defined $where;
    $sql .= ' GROUP BY ' . $groupby if defined $groupby;
    $sql .= ' ORDER BY time' unless defined $groupby;

    # Fetch and return all matching rows
    return $db->selectall_arrayref($sql);
}

# Retrieve the most recent log entry
sub log_retrieve_latest
{
    my ($self, $thermostat, $fields) = @_;

    # Fetch and return the matching row
    return $self->log_retrieve($thermostat, $fields, "time = (SELECT MAX(time) FROM temperatures WHERE thermostat='" . $thermostat . "')")->[0];
}

# Determine the daily min/max temperatures
sub log_daily_min_max
{
    my ($self, $thermostat, $where) = @_;

    # Fetch and return all matching rows
    return $self->log_retrieve($thermostat, [qw(date_time min_air max_air)],
                               $where, 'DATE(time)');
}

# Determine the date range of log entries
sub log_dates
{
    my ($self, $thermostat) = @_;

    # Fetch and return the date range
    return $self->log_retrieve($thermostat, [qw(min_time max_time)])->[0];
}

# Retrieve specified event entries
sub events_retrieve
{
    my ($self, $thermostat, $fields, $class, $where) = @_;

    # Connect to the database
    my $db = $self->db();

    # Construct columns to retrieve
    my @fields = @$fields;
    foreach my $field (@fields)
    {
        # Convert dates to the selected format
        $field = $self->date_from_mysql($field) if $field eq 'time';
    }

    # Convert a range specification into a WHERE clause
    $where = $self->where_range($where) if ref $where eq 'HASH';

    # Prepare the SQL statement to retrieve each event entry
    my $sql = 'SELECT ' . join(',', @fields) . ' FROM events';
    $sql .= " WHERE (class='" . $class . "')";
    $sql .= " AND (thermostat='" . $thermostat . "')";
    $sql .= ' AND (' . $where . ')' if defined $where;
    $sql .= ' ORDER BY time';

    # Fetch and return all matching rows
    return $db->selectall_arrayref($sql);
}

# Retrieve the settings
sub settings_retrieve
{
    my ($self, $thermostat) = @_;

    # Connect to the database
    my $db = $self->db();

    # Prepare the SQL statement to retrieve the settings
    my $sql = 'SELECT name, value FROM settings';
    $sql .= " WHERE (thermostat='" . $thermostat . "')";

    # Fetch and return all rows converted back to a hash
    my $statement = $db->prepare_cached($sql);
    $statement->execute();
    return map { @$_ } @{$statement->fetchall_arrayref()};
}

# Retrieve the comfort levels
sub comfort_retrieve
{
    my ($self, $thermostat) = @_;

    # Connect to the database
    my $db = $self->db();

    # Prepare the SQL statement to retrieve the comfort levels
    my $sql = 'SELECT * FROM comfort';
    $sql .= " WHERE (thermostat='" . $thermostat . "')";

    # Fetch all rows and convert back to a multi-dimensional table
    my $statement = $db->prepare_cached($sql);
    $statement->execute();
    my $comfort;
    while (my $row = $statement->fetchrow_hashref())
    {
        $comfort->[$row->{day}]->[$row->{entry}] = { time => $row->{time},
                                                     target => $row->{target} };
    }

    # Return the result
    return $comfort;
}

# Retrieve the timer program
sub timer_retrieve
{
    my ($self, $thermostat) = @_;

    # Connect to the database
    my $db = $self->db();

    # Prepare the SQL statement to retrieve the timer program
    my $sql = 'SELECT * FROM timer';
    $sql .= " WHERE (thermostat='" . $thermostat . "')";

    # Fetch all rows and convert back to a multi-dimensional table
    my $statement = $db->prepare_cached($sql);
    $statement->execute();
    my $timer;
    while (my $row = $statement->fetchrow_hashref())
    {
        $timer->[$row->{day}]->[$row->{entry}] = { on => $row->{timeon},
                                                   off => $row->{timeoff} };
    }

    # Return the result
    return $timer;
}

# Retrieve specified weather entries
sub weather_retrieve
{
    my ($self, $fields, $where, $groupby) = @_;

    # Connect to the database
    my $db = $self->db();

    # Construct columns to retrieve
    my @fields = @$fields;
    foreach my $field (@fields)
    {
        # Aggregated data
        my $op;
        $op = 'AVG' if defined $groupby;
        $op = uc $1 if $field =~ s/^(min|max|avg|count|date)_//i;
        $field = "$op($field)" if defined $op;

        # Convert dates to the selected format
        $field = $self->date_from_mysql($field) if $field =~ /\btime\b/;
    }

    # Convert a range specification into a WHERE clause
    $where = $self->where_range($where) if ref $where eq 'HASH';

    # Prepare the SQL statement to retrieve each log entry
    my $sql = 'SELECT ' . join(',', @fields) . ' FROM weather';
    $sql .= ' WHERE (' . $where . ')' if defined $where;
    $sql .= ' GROUP BY ' . $groupby if defined $groupby;
    $sql .= ' ORDER BY time' unless defined $groupby;

    # Fetch and return all matching rows
    return $db->selectall_arrayref($sql);
}

# Retrieve the most recent weather entry
sub weather_retrieve_latest
{
    my ($self, $fields) = @_;

    # Fetch and return the matching row
    return $self->weather_retrieve($fields, 'time = (SELECT MAX(time) FROM weather)')->[0];
}

# Determine the daily min/max temperatures
sub weather_daily_min_max
{
    my ($self, $where) = @_;

    # Fetch and return all matching rows
    return $self->weather_retrieve([qw(date_time min_external max_external)],
                                   $where, 'DATE(time)');
}

# Determine the date range of weather entries
sub weather_dates
{
    my ($self) = @_;

    # Fetch and return the date range
    return $self->weather_retrieve([qw(min_time max_time)])->[0];
}


# SQL WHERE CLAUSE GENERATION

# Range of dates and/or number of recent days
sub where_range
{
    my ($self, $range) = @_;

    # Construct the WHERE clause
    my @where;
    push @where, "DATE_SUB(NOW(), INTERVAL $range->{days} DAY) <= time" if defined $range->{days};
    push @where, $self->date_to_mysql($range->{from}) . ' <= time' if defined $range->{from};
    push @where, 'time < ' . $self->date_to_mysql($range->{to}) if defined $range->{to};

    # Return the result
    return @where ? '(' . join(' AND ', @where) . ')' : undef;
}


# SQL TO CONVERT BETWEEN DATE FORMATS

# Convert selected date format to MySQL
sub date_to_mysql
{
    my ($self, $date) = @_;

    # Return the appropriate SQL for the selected date format
    return "FROM_UNIXTIME($date/1000)" if $self->{dateformat} eq 'javascript';
    return $date; # (otherwise assume MySQL format)
}

# Use Javascript date format (milliseconds since 1st January 1970 epoch)
sub date_from_mysql
{
    my ($self, $date) = @_;

    # Return the appropriate SQL for the selected date format
    return "(UNIX_TIMESTAMP($date)*1000)" if $self->{dateformat} eq 'javascript';
    return $date; # (otherwise assume MySQL format)
}


# Module loaded correctly
1;
