-- Records the server version and the connection port so docs can cite a results file.
SELECT VERSION() AS mysql_version, @@version_comment AS version_comment, @@port AS server_port;
