-- Base dédiée au bridge mautrix-whatsapp (Synapse garde « synapse »).
CREATE DATABASE mautrix_whatsapp
  OWNER matrix
  ENCODING 'UTF8'
  LC_COLLATE 'C'
  LC_CTYPE 'C'
  TEMPLATE template0;

-- Base dédiée au bridge Instagram (image mautrix/meta, binaire mautrix-instagram).
CREATE DATABASE mautrix_meta
  OWNER matrix
  ENCODING 'UTF8'
  LC_COLLATE 'C'
  LC_CTYPE 'C'
  TEMPLATE template0;
