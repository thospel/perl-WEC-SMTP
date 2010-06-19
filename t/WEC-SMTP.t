# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl WEC-SMTP.t'
#########################

use Test::More tests => 2;
# BEGIN { use_ok('WEC::SMTP::Client') };
BEGIN { use_ok('WEC::SMTP::Server') };
BEGIN { use_ok('WEC::SMTP::Client') };

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.
