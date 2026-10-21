-- Lists the privileges of the connecting admin account (read-only), so the setup draft can mirror them.
SHOW GRANTS FOR CURRENT_USER();
SELECT CURRENT_USER() AS connected_as;
