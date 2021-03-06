;;;
;;; Generic API for pgloader sources
;;; Methods for database source types (with introspection)
;;;

(in-package :pgloader.sources)

;;;
;;; Prepare the PostgreSQL database before streaming the data into it.
;;;
(defmethod prepare-pgsql-database ((copy db-copy)
                                   (catalog catalog)
                                   &key
                                     truncate
                                     create-tables
                                     create-schemas
                                     set-table-oids
                                     materialize-views
                                     foreign-keys
                                     include-drop)
  "Prepare the target PostgreSQL database: create tables casting datatypes
   from the MySQL definitions, prepare index definitions and create target
   tables for materialized views.

   That function mutates index definitions in ALL-INDEXES."
  (log-message :notice "~:[~;DROP then ~]CREATE TABLES" include-drop)

  (with-pgsql-transaction (:pgconn (target-db copy))
    (when create-schemas
      (with-stats-collection ("Create Schemas" :section :pre
                                               :use-result-as-read t
                                               :use-result-as-rows t)
        (create-schemas catalog :include-drop include-drop)))

    (if create-tables
        (progn
          ;; create new SQL types (ENUMs, SETs) if needed and before we
          ;; get to the table definitions that will use them
          (with-stats-collection ("Create SQL Types" :section :pre
                                                     :use-result-as-read t
                                                     :use-result-as-rows t)
            (create-sqltypes catalog
                             :include-drop include-drop
                             :client-min-messages :error))

          ;; now the tables
          (with-stats-collection ("Create tables" :section :pre
                                                  :use-result-as-read t
                                                  :use-result-as-rows t)
            (create-tables catalog
                           :include-drop include-drop
                           :client-min-messages :error)))

        (progn
          ;; if we're not going to create the tables, now is the time to
          ;; remove the constraints: indexes, primary keys, foreign keys
          ;;
          ;; to be able to do that properly, get the constraints from
          ;; the pre-existing target database catalog
          (let ((pgsql-catalog
                 (fetch-pgsql-catalog (db-name (target-db copy))
                                      :source-catalog catalog)))
            (merge-catalogs catalog pgsql-catalog))

          ;; now the foreign keys and only then the indexes, because a
          ;; drop constraint on a primary key cascades to the drop of
          ;; any foreign key that targets the primary key
          (when foreign-keys
            (with-stats-collection ("Drop Foreign Keys" :section :pre
                                                        :use-result-as-read t
                                                        :use-result-as-rows t)
              (drop-pgsql-fkeys catalog)))

          (with-stats-collection ("Drop Indexes" :section :pre
                                                 :use-result-as-read t
                                                 :use-result-as-rows t)
            ;; we want to error out early in case we can't DROP the
            ;; index, don't CASCADE
            (drop-indexes catalog :cascade nil))

          (when truncate
            (with-stats-collection ("Truncate" :section :pre
                                               :use-result-as-read t
                                               :use-result-as-rows t)
              (truncate-tables catalog)))))

    ;; Some database sources allow the same index name being used
    ;; against several tables, so we add the PostgreSQL table OID in the
    ;; index name, to differenciate. Set the table oids now.
    (when (and create-tables set-table-oids)
      (with-stats-collection ("Set Table OIDs" :section :pre
                                               :use-result-as-read t
                                               :use-result-as-rows t)
        (set-table-oids catalog)))

    ;; We might have to MATERIALIZE VIEWS
    (when materialize-views
      (with-stats-collection ("Create MatViews Tables" :section :pre
                                                       :use-result-as-read t
                                                       :use-result-as-rows t)
        (create-views catalog :include-drop include-drop))))

  ;; log the catalog we just fetched and (maybe) merged
  (log-message :data "CATALOG: ~s" catalog))

(defmethod cleanup ((copy db-copy) (catalog catalog) &key materialize-views)
  "In case anything wrong happens at `prepare-pgsql-database' step, this
  function will be called to clean-up the mess left behind, if any."
  (declare (ignorable materialize-views))
  t)

(defmethod complete-pgsql-database ((copy db-copy)
                                    (catalog catalog)
                                    pkeys
                                    &key
                                      data-only
                                      foreign-keys
                                      create-triggers
                                      reset-sequences)
  "After loading the data into PostgreSQL, we can now reset the sequences
     and declare foreign keys."
  ;;
  ;; Now Reset Sequences, the good time to do that is once the whole data
  ;; has been imported and once we have the indexes in place, as max() is
  ;; able to benefit from the indexes. In particular avoid doing that step
  ;; while CREATE INDEX statements are in flight (avoid locking).
  ;;
  (when reset-sequences
    (reset-sequences (clone-connection (target-db copy)) catalog))

  (with-pgsql-connection ((clone-connection (target-db copy)))
    ;;
    ;; Turn UNIQUE indexes into PRIMARY KEYS now
    ;;
    (unless data-only
      (pgsql-execute-with-timing :post "Primary Keys"
                                 pkeys
                                 :count (length pkeys))

      ;;
      ;; Foreign Key Constraints
      ;;
      ;; We need to have finished loading both the reference and the refering
      ;; tables to be able to build the foreign keys, so wait until all tables
      ;; and indexes are imported before doing that.
      ;;
      (when foreign-keys
        (with-stats-collection ("Create Foreign Keys" :section :post
                                                      :use-result-as-read t
                                                      :use-result-as-rows t)
          (create-pgsql-fkeys catalog)))

      ;;
      ;; Triggers and stored procedures -- includes special default values
      ;;
      (when create-triggers
        (with-stats-collection ("Create Triggers" :section :post
                                                  :use-result-as-read t
                                                  :use-result-as-rows t)
          (with-pgsql-transaction (:pgconn (target-db copy))
            (create-triggers catalog)))))

    ;;
    ;; And now, comments on tables and columns.
    ;;
    (with-stats-collection ("Install Comments" :section :post
                                               :use-result-as-read t
                                               :use-result-as-rows t)
      (comment-on-tables-and-columns catalog))))

(defmethod instanciate-table-copy-object ((copy db-copy) (table table))
  "Create an new instance for copying TABLE data."
  (let* ((fields     (table-field-list table))
         (columns    (table-column-list table))
         (transforms (mapcar #'column-transform columns)))
    (make-instance (class-of copy)
                   :source-db  (clone-connection (source-db copy))
                   :target-db  (clone-connection (target-db copy))
                   :source     table
                   :target     table
                   :fields     fields
                   :columns    columns
                   :transforms transforms)))

(defun process-catalog (copy catalog &key alter-table alter-schema)
  "Do all the PostgreSQL catalog tweaking here: casts, index WHERE clause
   rewriting, pgloader level alter schema and alter table commands."
  ;; cast the catalog into something PostgreSQL can work on
  (cast catalog)

  ;; support code for index filters (where clauses)
  (process-index-definitions catalog :sql-dialect (class-name (class-of copy)))

  ;; we may have to alter schemas
  (when alter-schema
    (alter-schema catalog alter-schema))

  ;; if asked, now alter the catalog with given rules: the alter-table
  ;; keyword parameter actually contains a set of alter table rules.
  (when alter-table
    (alter-table catalog alter-table)))


;;;
;;; Generic enough implementation of the copy-database method.
;;;
(defmethod copy-database ((copy db-copy)
			  &key
                            (on-error-stop    *on-error-stop*)
                            (worker-count     4)
                            (concurrency      1)
                            max-parallel-create-index
			    (truncate         nil)
			    (disable-triggers nil)
			    (data-only        nil)
			    (schema-only      nil)
                            (create-schemas   nil)
			    (create-tables    t)
			    (include-drop     t)
			    (create-indexes   t)
                            (index-names      :uniquify)
			    (reset-sequences  t)
			    (foreign-keys     t)
			    only-tables
			    including
			    excluding
                            set-table-oids
                            alter-table
                            alter-schema
			    materialize-views)
  "Export database source data and Import it into PostgreSQL"
  (let* ((copy-kernel  (make-kernel worker-count))
         (copy-channel (let ((lp:*kernel* copy-kernel)) (lp:make-channel)))
         (catalog      (fetch-metadata
                        copy
                        (make-catalog
                         :name (typecase (source-db copy)
                                 (db-connection (db-name (source-db copy)))
                                 (fd-connection (pathname-name
                                                 (fd-path (source-db copy))))))
                        :materialize-views materialize-views
                        :only-tables only-tables
                        :create-indexes create-indexes
                        :foreign-keys foreign-keys
                        :including including
                        :excluding excluding))
         pkeys
         (writers-count (make-hash-table :size (count-tables catalog)))
         (max-indexes   (when create-indexes
                          (max-indexes-per-table catalog)))
         (idx-kernel    (when (and max-indexes (< 0 max-indexes))
                          (make-kernel (or max-parallel-create-index
                                           max-indexes))))
         (idx-channel   (when idx-kernel
                          (let ((lp:*kernel* idx-kernel))
                            (lp:make-channel)))))

    ;; apply catalog level transformations to support the database migration
    ;; that's CAST rules, index WHERE clause rewriting and ALTER commands
    (process-catalog copy catalog
                     :alter-table alter-table
                     :alter-schema alter-schema)

    ;; if asked, first drop/create the tables on the PostgreSQL side
    (handler-case
        (prepare-pgsql-database copy
                                catalog
                                :truncate (and truncate (not create-tables))
                                :create-tables (and create-tables
                                                    (or schema-only
                                                        (not data-only)))
                                :create-schemas (and create-schemas
                                                     (or schema-only
                                                         (not data-only)))
                                :include-drop include-drop
                                :foreign-keys (and foreign-keys
                                                   (or schema-only
                                                       (not data-only)))
                                :set-table-oids set-table-oids
                                :materialize-views materialize-views)
      ;;
      ;; In case some error happens in the preparatory transaction, we
      ;; need to stop now and refrain from trying to load the data into
      ;; an incomplete schema.
      ;;
      (cl-postgres:database-error (e)
        (declare (ignore e))		; a log has already been printed
        (log-message :fatal "Failed to create the schema, see above.")

        ;; we might have some cleanup to do...
        (cleanup copy catalog :materialize-views materialize-views)

        (return-from copy-database)))

    (loop
       :for table :in (append (table-list catalog)
                              ;; when materialized views are not supported,
                              ;; view-list is empty here
                              (view-list catalog))

       :do (let ((table-source (instanciate-table-copy-object copy table)))
             ;; first COPY the data from source to PostgreSQL, using copy-kernel
             (unless schema-only
               ;; prepare the writers-count hash-table, as we start
               ;; copy-from, we have concurrency tasks writing.
               (setf (gethash table writers-count) concurrency)
               (copy-from table-source
                          :concurrency concurrency
                          :kernel copy-kernel
                          :channel copy-channel
                          :on-error-stop on-error-stop
                          :disable-triggers disable-triggers))))

    ;; now end the kernels
    ;; and each time a table is done, launch its indexing
    (unless schema-only
      (let ((lp:*kernel* copy-kernel))
        (with-stats-collection ("COPY Threads Completion" :section :post
                                                          :use-result-as-read t
                                                          :use-result-as-rows t)
            (let ((worker-count (* (hash-table-count writers-count)
                                   (task-count concurrency))))
              (loop :for tasks :below worker-count
                 :do (destructuring-bind (task table seconds)
                         (lp:receive-result copy-channel)
                       (log-message :debug
                                    "Finished processing ~a for ~s ~50T~6$s"
                                    task (format-table-name table) seconds)
                       (when (eq :writer task)
                         (update-stats :data table :secs seconds)

                         ;;
                         ;; Start the CREATE INDEX parallel tasks only when
                         ;; the data has been fully copied over to the
                         ;; corresponding table, that's when the writers
                         ;; count is down to zero.
                         ;;
                         (decf (gethash table writers-count))
                         (log-message :debug "writers-counts[~a] = ~a"
                                      (format-table-name table)
                                      (gethash table writers-count))

                         (when (and create-indexes
                                    (not data-only)
                                    (zerop (gethash table writers-count)))
                           (let* ((*preserve-index-names*
                                   (or (eq :preserve index-names)
                                       ;; if we didn't create the tables, we
                                       ;; are re-installing the pre-existing
                                       ;; indexes
                                       (not create-tables))))
                             (alexandria:appendf
                              pkeys
                              (create-indexes-in-kernel (target-db copy)
                                                        table
                                                        idx-kernel
                                                        idx-channel)))))))
              (prog1
                  worker-count
                (lp:end-kernel :wait nil))))))

    (when create-indexes
      (let ((lp:*kernel* idx-kernel))
        ;; wait until the indexes are done being built...
        ;; don't forget accounting for that waiting time.
        (with-stats-collection ("Index Build Completion" :section :post
                                                         :use-result-as-read t
                                                         :use-result-as-rows t)
            (loop :for count :below (count-indexes catalog)
               :do (lp:receive-result idx-channel))
          (lp:end-kernel :wait t)
          (count-indexes catalog))))

    ;;
    ;; Complete the PostgreSQL database before handing over.
    ;;
    (complete-pgsql-database copy
                             catalog
                             pkeys
                             :data-only data-only
                             :foreign-keys foreign-keys
                             ;; only create triggers (for default values)
                             ;; when we've been responsible for creating the
                             ;; tables -- otherwise assume the schema is
                             ;; good as it is
                             :create-triggers create-tables
                             :reset-sequences reset-sequences)

    ;;
    ;; Time to cleanup!
    ;;
    (cleanup copy catalog :materialize-views materialize-views)))
