-- Load new tables
-- set def OFF then to '&' to avoid misleading SP2-0317 error.
set def OFF
set echo off feedback off sqlprompt '' def &
prompt
prompt Loading PhEDEx schema to &_user@&_connect_identifier

prompt
prompt Loading topology
@@OracleCoreTopo.sql

prompt Loading administration
@@OracleCoreAdm.sql

prompt Loading agents
@@OracleCoreAgents.sql

prompt
prompt Loading data placement
@@OracleCoreBlock.sql

prompt
prompt Loading files
@@OracleCoreFiles.sql

prompt Loading transfers
@@OracleCoreTransfer.sql

prompt
prompt Loading request management
@@OracleCoreReq.sql

prompt Loading transfer triggers
@@OracleCoreTriggers.sql

prompt
prompt Loading status
@@OracleCoreStatus.sql

prompt
prompt Loading loadtest
@@OracleCoreLoadTest.sql

prompt
prompt Loading block verification
@@OracleCoreVerify.sql

prompt
prompt Loading helper functions
@@OracleCoreFunctions.sql

prompt
prompt Loading vies
@@OracleCoreViews.sql

prompt
prompt PhEDEx schema loaded
prompt
