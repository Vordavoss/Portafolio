/* =============================================================================
   JOB DE HOMOLOGACIÓN DE PRECIOS - XposStore
   -----------------------------------------------------------------------------
   Se instala y se ejecuta en la Caja 2 (caja servidora).

   Flujo:
     1. Toma un lock exclusivo. Si ya hay una ejecución en curso, se omite.
     2. Valida la conexión con todas las cajas. Si alguna no responde,
        registra el error y cancela todo el proceso.
     3. Extrae los precios activos de cada caja.
     4. Compara por SKU y tipo de precio.
     5. Precio ganador: el de la fecha más reciente (modificación o creación).
     6. @SoloReporte = 1 -> solo muestra lo que se cambiaría.
        @SoloReporte = 0 -> actualiza las cajas con el precio desactualizado.
     7. Registra todo en la bitácora.

   Reglas:
     - SKU que no existe en una caja: se reporta, no se crea.
     - Empate (misma fecha más reciente con precios distintos): se reporta.
     - SKU con más de un precio activo del mismo tipo en una caja: se reporta.
     - La caja actualizada recibe el precio y la fecha del precio ganador.

   Contenido del script:
     1. Base de control y tablas
     2. Configuración de cajas y tipos de precio
     3. Procedimiento dbo.usp_HomologarPrecios
     4. Ejecución
     5. Servidores vinculados (producción)
     6. Tarea programada (producción)
   ============================================================================= */


/* =============================================================================
   1. BASE DE CONTROL Y TABLAS
   ============================================================================= */
IF DB_ID(N'HomologacionPrecios') IS NULL
    CREATE DATABASE HomologacionPrecios;
GO
USE HomologacionPrecios;
GO

-- Cajas que participan en la homologación
IF OBJECT_ID(N'dbo.Cajas') IS NULL
CREATE TABLE dbo.Cajas (
    Caja      varchar(20) NOT NULL PRIMARY KEY,  -- nombre en reportes y bitácora
    Servidor  sysname     NULL,                  -- servidor vinculado; NULL = misma instancia
    BaseDatos sysname     NOT NULL,
    Activa    bit         NOT NULL DEFAULT 1
);

-- Tipos de precio que se comparan
IF OBJECT_ID(N'dbo.TiposPrecio') IS NULL
CREATE TABLE dbo.TiposPrecio (
    TipoPrecio varchar(50) NOT NULL PRIMARY KEY,
    Activo     bit         NOT NULL DEFAULT 1
);

-- Una fila por ejecución
IF OBJECT_ID(N'dbo.Job_Homologacion_Precios_Ejecucion') IS NULL
CREATE TABLE dbo.Job_Homologacion_Precios_Ejecucion (
    EjecucionID    int IDENTITY(1,1) PRIMARY KEY,
    Inicio         datetime2(0)   NOT NULL DEFAULT SYSDATETIME(),
    Fin            datetime2(0)   NULL,
    Modo           varchar(10)    NOT NULL,  -- REPORTE / CORRECCION
    Status         varchar(20)    NOT NULL,  -- EN_CURSO / OK / PARCIAL / CANCELADO / ERROR / OMITIDO
    SKUsComparados int            NULL,
    SKUsDiferentes int            NULL,
    Cambios        int            NULL,      -- precios por actualizar (o actualizados)
    PorRevisar     int            NULL,      -- faltantes, empates y duplicados
    Mensaje        nvarchar(4000) NULL
);

-- Detalle: una fila por SKU, tipo de precio y caja
IF OBJECT_ID(N'dbo.Job_Homologacion_Precios_Log') IS NULL
CREATE TABLE dbo.Job_Homologacion_Precios_Log (
    LogID               bigint IDENTITY(1,1) PRIMARY KEY,
    EjecucionID         int            NOT NULL,
    ExecutionDate       datetime2(0)   NOT NULL DEFAULT SYSDATETIME(),
    SKU                 varchar(100)   NULL,
    PriceType           varchar(50)    NULL,
    Caja                varchar(20)    NULL,
    Previous_Price      decimal(18,4)  NULL,
    Winning_Price       decimal(18,4)  NULL,
    Winning_Source_Caja varchar(100)   NULL,
    Winning_Date        datetime       NULL,
    Accion              varchar(20)    NOT NULL,  -- ACTUALIZAR / SIN_SKU / EMPATE / DUPLICADO / CAJA_OFFLINE
    Status              varchar(20)    NOT NULL,  -- SIMULADO / APLICADO / REVISAR / ERROR / CANCELADO
    Mensaje             nvarchar(4000) NULL
);
GO


/* =============================================================================
   2. CONFIGURACIÓN
   ============================================================================= */
-- Ambiente de pruebas: las tres bases en la misma instancia
IF NOT EXISTS (SELECT 1 FROM dbo.Cajas)
INSERT dbo.Cajas (Caja, Servidor, BaseDatos) VALUES
    ('CAJA1', NULL, N'XposStore_50LP1_v1'),
    ('CAJA2', NULL, N'XposStore_50LP1_P2'),
    ('CAJA3', NULL, N'XposStore_50LP1_v3');

-- Producción: la Caja 2 es local y las demás por servidor vinculado (sección 5)
-- INSERT dbo.Cajas (Caja, Servidor, BaseDatos) VALUES
--     ('CAJA1', N'LNK_CAJA1', N'XposStore'),
--     ('CAJA2', NULL,         N'XposStore'),
--     ('CAJA3', N'LNK_CAJA3', N'XposStore');

IF NOT EXISTS (SELECT 1 FROM dbo.TiposPrecio)
INSERT dbo.TiposPrecio (TipoPrecio, Activo) VALUES
    ('SALE_PRICE', 1),
    ('COST_PRICE', 0),
    ('LOW_PRICE',  0);
GO


/* =============================================================================
   3. PROCEDIMIENTO
   ============================================================================= */
CREATE OR ALTER PROCEDURE dbo.usp_HomologarPrecios
    @SoloReporte bit = 1   -- 1 = solo muestra lo que se cambiaría; 0 = aplica los cambios
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @EjecucionID int,
            @Modo        varchar(10) = CASE WHEN @SoloReporte = 1 THEN 'REPORTE'
                                            ELSE 'CORRECCION' END,
            @Status      varchar(20),
            @Mensaje     nvarchar(4000),
            @Lock        int,
            @Caja        varchar(20),
            @Servidor    sysname,
            @Prefijo     nvarchar(300),
            @Exec        nvarchar(400),
            @Sql         nvarchar(max),
            @Tipos       nvarchar(max),
            @Valores     nvarchar(max),
            @Lote        int,
            @Esperadas   int,
            @Errores     int = 0;
    DECLARE @Filas TABLE (n int);

    ---------------------------------------------------------------------------
    -- 1. Lock: solo una ejecución a la vez
    ---------------------------------------------------------------------------
    EXEC @Lock = sp_getapplock @Resource = N'Job_Homologacion_Precios',
                               @LockMode = N'Exclusive',
                               @LockOwner = N'Session',
                               @LockTimeout = 0;
    IF @Lock < 0
    BEGIN
        INSERT dbo.Job_Homologacion_Precios_Ejecucion (Modo, Status, Fin, Mensaje)
        VALUES (@Modo, 'OMITIDO', SYSDATETIME(), N'Ya hay una ejecución en curso.');
        RAISERROR(N'Ya hay una ejecución en curso. Esta ejecución se omite.', 10, 1)
            WITH NOWAIT;
        RETURN 1;
    END

    INSERT dbo.Job_Homologacion_Precios_Ejecucion (Modo, Status) VALUES (@Modo, 'EN_CURSO');
    SET @EjecucionID = SCOPE_IDENTITY();

    BEGIN TRY
        CREATE TABLE #Cajas (
            Caja      varchar(20)    NOT NULL PRIMARY KEY,
            Servidor  sysname        NULL,
            Prefijo   nvarchar(300)  NOT NULL,   -- [BaseDatos].dbo.
            EnLinea   bit            NULL,
            Mensaje   nvarchar(4000) NULL
        );
        CREATE TABLE #Precios (
            Caja       varchar(20)   NOT NULL,
            SKU        varchar(100)  NOT NULL,
            Precio     decimal(18,4) NULL,
            TipoPrecio varchar(50)   NOT NULL,
            Modificado datetime      NULL,
            Creado     datetime      NULL,
            FechaRef   AS CASE WHEN Modificado IS NULL OR Creado > Modificado
                               THEN Creado ELSE Modificado END
        );

        INSERT #Cajas (Caja, Servidor, Prefijo)
        SELECT Caja, Servidor, QUOTENAME(BaseDatos) + N'.dbo.'
        FROM dbo.Cajas
        WHERE Activa = 1;

        SELECT @Tipos = STRING_AGG(CAST(N'''' + REPLACE(TipoPrecio, N'''', N'''''') + N''''
                                        AS nvarchar(max)), N', ')
        FROM dbo.TiposPrecio
        WHERE Activo = 1;

        IF (SELECT COUNT(*) FROM #Cajas) < 2
            THROW 50001, N'Se requieren al menos dos cajas activas en dbo.Cajas.', 1;
        IF @Tipos IS NULL
            THROW 50002, N'No hay tipos de precio activos en dbo.TiposPrecio.', 1;

        -----------------------------------------------------------------------
        -- 2. Validar conexión con todas las cajas
        -----------------------------------------------------------------------
        DECLARE cur_cajas CURSOR LOCAL STATIC FOR
            SELECT Caja, Servidor, Prefijo FROM #Cajas ORDER BY Caja;

        OPEN cur_cajas;
        FETCH NEXT FROM cur_cajas INTO @Caja, @Servidor, @Prefijo;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Exec = CASE WHEN @Servidor IS NULL THEN N'EXEC (@q);'
                             ELSE N'EXEC (@q) AT ' + QUOTENAME(@Servidor) + N';' END;
            BEGIN TRY
                IF @Servidor IS NOT NULL
                    EXEC sp_testlinkedserver @Servidor;

                SET @Sql = N'SELECT TOP (0) 1 FROM ' + @Prefijo + N'PRICE;';
                EXEC sp_executesql @Exec, N'@q nvarchar(max)', @q = @Sql;

                UPDATE #Cajas SET EnLinea = 1 WHERE Caja = @Caja;
            END TRY
            BEGIN CATCH
                UPDATE #Cajas SET EnLinea = 0, Mensaje = ERROR_MESSAGE() WHERE Caja = @Caja;
            END CATCH;
            FETCH NEXT FROM cur_cajas INTO @Caja, @Servidor, @Prefijo;
        END
        CLOSE cur_cajas;

        -----------------------------------------------------------------------
        -- 3. Extraer precios (solo si todas las cajas están en línea)
        -----------------------------------------------------------------------
        IF NOT EXISTS (SELECT 1 FROM #Cajas WHERE EnLinea = 0)
        BEGIN
            OPEN cur_cajas;
            FETCH NEXT FROM cur_cajas INTO @Caja, @Servidor, @Prefijo;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @Exec = CASE WHEN @Servidor IS NULL THEN N'EXEC (@q);'
                                 ELSE N'EXEC (@q) AT ' + QUOTENAME(@Servidor) + N';' END;
                SET @Sql = N'SELECT ' + QUOTENAME(@Caja, N'''') + N', i.SKU, p.AMOUNT, pt.NAME,'
                         + N' p.modified_datetime, p.created_datetime'
                         + N' FROM ' + @Prefijo + N'item AS i'
                         + N' JOIN ' + @Prefijo + N'ITEM_BUSINESS_UNIT_LINK AS il'
                         + N'   ON il.ITEM_ID = i.ITEM_ID'
                         + N' JOIN ' + @Prefijo + N'PRICE AS p'
                         + N'   ON p.ITEM_BUSINESS_UNIT_LINK_ID = il.ITEM_BUSINESS_UNIT_LINK_ID'
                         + N' JOIN ' + @Prefijo + N'code AS pt ON pt.CODE_ID = p.PRICE_TYPE_CODE_ID'
                         + N' JOIN ' + @Prefijo + N'code AS it ON it.CODE_ID = i.ITEM_TYPE_CODE_ID'
                         + N' WHERE i.IS_ACTIVE = 1 AND p.IS_ACTIVE = 1'
                         + N'   AND it.NAME = ''PRODUCT_ITEM'''
                         + N'   AND pt.NAME IN (' + @Tipos + N');';
                BEGIN TRY
                    INSERT #Precios (Caja, SKU, Precio, TipoPrecio, Modificado, Creado)
                    EXEC sp_executesql @Exec, N'@q nvarchar(max)', @q = @Sql;
                END TRY
                BEGIN CATCH
                    UPDATE #Cajas SET EnLinea = 0, Mensaje = ERROR_MESSAGE() WHERE Caja = @Caja;
                    BREAK;   -- una caja falló: se cancela todo
                END CATCH;
                FETCH NEXT FROM cur_cajas INTO @Caja, @Servidor, @Prefijo;
            END
            CLOSE cur_cajas;
        END
        DEALLOCATE cur_cajas;

        -----------------------------------------------------------------------
        -- Caja sin conexión: registrar y cancelar todo el proceso
        -----------------------------------------------------------------------
        IF EXISTS (SELECT 1 FROM #Cajas WHERE EnLinea = 0)
        BEGIN
            INSERT dbo.Job_Homologacion_Precios_Log
                   (EjecucionID, Caja, Accion, Status, Mensaje)
            SELECT @EjecucionID, Caja, 'CAJA_OFFLINE', 'CANCELADO', Mensaje
            FROM #Cajas
            WHERE EnLinea = 0;

            SELECT @Status  = 'CANCELADO',
                   @Mensaje = N'Proceso cancelado. Cajas sin conexión: '
                            + STRING_AGG(CAST(Caja AS nvarchar(max)), N', ')
            FROM #Cajas
            WHERE EnLinea = 0;

            SELECT Caja,
                   CASE EnLinea WHEN 1 THEN 'EN LINEA'
                                WHEN 0 THEN 'SIN CONEXION'
                                ELSE 'NO VALIDADA' END AS Estado,
                   Mensaje
            FROM #Cajas
            ORDER BY Caja;
        END
        ELSE
        BEGIN
            -------------------------------------------------------------------
            -- 4. Comparativa por SKU, tipo de precio y caja
            -------------------------------------------------------------------
            SELECT k.SKU, k.TipoPrecio, c.Caja,
                   ISNULL(p.Filas, 0) AS Filas,     -- 0 = no existe, >1 = duplicado
                   p.Precio, p.FechaRef
            INTO #Detalle
            FROM (SELECT DISTINCT SKU, TipoPrecio FROM #Precios) AS k
            CROSS JOIN #Cajas AS c
            OUTER APPLY (SELECT COUNT(*) AS Filas, MAX(x.Precio) AS Precio,
                                MAX(x.FechaRef) AS FechaRef
                         FROM #Precios AS x
                         WHERE x.SKU = k.SKU AND x.TipoPrecio = k.TipoPrecio
                           AND x.Caja = c.Caja
                         HAVING COUNT(*) > 0) AS p;

            SELECT d.SKU, d.TipoPrecio,
                   SUM(CASE WHEN d.Filas = 0 THEN 1 ELSE 0 END) AS Faltantes,
                   SUM(CASE WHEN d.Filas > 1 THEN 1 ELSE 0 END) AS Duplicados,
                   ISNULL(u.Precios, 0) AS Precios,
                   u.FechaMax,
                   CAST(NULL AS varchar(12))    AS Estatus,
                   CAST(NULL AS decimal(18,4))  AS PrecioGanador,
                   CAST(NULL AS varchar(100))   AS CajaGanadora,
                   CAST(0 AS bit)               AS Empate
            INTO #Resumen
            FROM #Detalle AS d
            OUTER APPLY (SELECT COUNT(DISTINCT x.Precio) AS Precios,
                                MAX(x.FechaRef) AS FechaMax
                         FROM #Detalle AS x
                         WHERE x.SKU = d.SKU AND x.TipoPrecio = d.TipoPrecio
                           AND x.Filas = 1 AND x.Precio IS NOT NULL
                         HAVING COUNT(*) > 0) AS u
            GROUP BY d.SKU, d.TipoPrecio, u.Precios, u.FechaMax;

            UPDATE #Resumen
               SET Estatus = CASE WHEN Faltantes = 0 AND Duplicados = 0 AND Precios = 1
                                  THEN 'IGUALES' ELSE 'DIFERENTES' END;

            -------------------------------------------------------------------
            -- 5. Precio ganador: fecha más reciente entre las cajas
            -------------------------------------------------------------------
            UPDATE r
               SET PrecioGanador = g.Precio,
                   CajaGanadora  = g.Cajas,
                   Empate        = CASE WHEN g.Precios > 1 THEN 1 ELSE 0 END
            FROM #Resumen AS r
            CROSS APPLY (SELECT MIN(d.Precio) AS Precio,
                                COUNT(DISTINCT d.Precio) AS Precios,
                                STRING_AGG(d.Caja, ',') WITHIN GROUP (ORDER BY d.Caja) AS Cajas
                         FROM #Detalle AS d
                         WHERE d.SKU = r.SKU AND d.TipoPrecio = r.TipoPrecio
                           AND d.Filas = 1 AND d.FechaRef = r.FechaMax) AS g
            WHERE r.Estatus = 'DIFERENTES';

            UPDATE #Resumen
               SET Empate = 1
            WHERE Estatus = 'DIFERENTES' AND Duplicados = 0 AND PrecioGanador IS NULL;

            UPDATE #Resumen
               SET PrecioGanador = NULL, CajaGanadora = NULL
            WHERE Empate = 1 OR Duplicados > 0;

            -------------------------------------------------------------------
            -- 6. Acciones por caja
            -------------------------------------------------------------------
            SELECT d.SKU, d.TipoPrecio, d.Caja, d.Precio AS PrecioActual,
                   r.PrecioGanador, r.CajaGanadora, r.FechaMax AS FechaGanadora,
                   a.Accion,
                   CASE WHEN a.Accion = 'ACTUALIZAR' THEN 'SIMULADO' ELSE 'REVISAR' END AS Status,
                   CAST(NULL AS int) AS Lote,
                   CAST(NULL AS nvarchar(4000)) AS Mensaje
            INTO #Acciones
            FROM #Detalle AS d
            JOIN #Resumen AS r ON r.SKU = d.SKU AND r.TipoPrecio = d.TipoPrecio
            CROSS APPLY (SELECT CASE
                    WHEN r.Duplicados > 0 AND d.Filas > 1           THEN 'DUPLICADO'
                    WHEN r.Duplicados > 0                           THEN NULL
                    WHEN r.Empate = 1 AND d.Filas = 1
                         AND d.FechaRef = r.FechaMax                THEN 'EMPATE'
                    WHEN r.Empate = 1                               THEN NULL
                    WHEN d.Filas = 0                                THEN 'SIN_SKU'
                    WHEN d.Precio <> r.PrecioGanador                THEN 'ACTUALIZAR'
                 END AS Accion) AS a
            WHERE r.Estatus = 'DIFERENTES'
              AND a.Accion IS NOT NULL;

            -------------------------------------------------------------------
            -- 7. Aplicar cambios (solo con @SoloReporte = 0)
            -------------------------------------------------------------------
            IF @SoloReporte = 0 AND EXISTS (SELECT 1 FROM #Acciones WHERE Accion = 'ACTUALIZAR')
            BEGIN
                -- Lotes de 500 precios por caja
                WITH n AS (
                    SELECT Lote, ROW_NUMBER() OVER (PARTITION BY Caja
                                                    ORDER BY SKU, TipoPrecio) AS rn
                    FROM #Acciones
                    WHERE Accion = 'ACTUALIZAR')
                UPDATE n SET Lote = (rn - 1) / 500;

                DECLARE cur_lotes CURSOR LOCAL STATIC FOR
                    SELECT DISTINCT a.Caja, c.Servidor, c.Prefijo, a.Lote
                    FROM #Acciones AS a
                    JOIN #Cajas AS c ON c.Caja = a.Caja
                    WHERE a.Accion = 'ACTUALIZAR'
                    ORDER BY a.Caja, a.Lote;

                OPEN cur_lotes;
                FETCH NEXT FROM cur_lotes INTO @Caja, @Servidor, @Prefijo, @Lote;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    -- Si un lote anterior de esta caja falló, no se intenta el resto
                    IF EXISTS (SELECT 1 FROM #Acciones WHERE Caja = @Caja AND Status = 'ERROR')
                    BEGIN
                        UPDATE #Acciones
                           SET Status = 'ERROR',
                               Mensaje = N'No se aplicó: falló un lote anterior de esta caja.'
                        WHERE Caja = @Caja AND Lote = @Lote;
                        FETCH NEXT FROM cur_lotes INTO @Caja, @Servidor, @Prefijo, @Lote;
                        CONTINUE;
                    END

                    SELECT @Valores = STRING_AGG(CAST(
                                N'(N''' + REPLACE(SKU, N'''', N'''''') + N''', N'''
                              + REPLACE(TipoPrecio, N'''', N'''''') + N''', '
                              + CONVERT(nvarchar(40), PrecioGanador) + N', '
                              + ISNULL(N'CONVERT(datetime, ''' + CONVERT(nvarchar(23), FechaGanadora, 121)
                                       + N''', 121)', N'NULL') + N')'
                              AS nvarchar(max)), N', '),
                           @Esperadas = COUNT(*)
                    FROM #Acciones
                    WHERE Caja = @Caja AND Lote = @Lote;

                    SET @Exec = CASE WHEN @Servidor IS NULL THEN N'EXEC (@q);'
                                     ELSE N'EXEC (@q) AT ' + QUOTENAME(@Servidor) + N';' END;
                    SET @Sql = N'SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;'
                             + N' UPDATE p SET p.AMOUNT = v.Precio,'
                             + N'   p.modified_datetime = ISNULL(v.Fecha, p.modified_datetime)'
                             + N' FROM (VALUES ' + @Valores + N') AS v(SKU, TipoPrecio, Precio, Fecha)'
                             + N' JOIN ' + @Prefijo + N'item AS i ON i.SKU = v.SKU'
                             + N' JOIN ' + @Prefijo + N'ITEM_BUSINESS_UNIT_LINK AS il'
                             + N'   ON il.ITEM_ID = i.ITEM_ID'
                             + N' JOIN ' + @Prefijo + N'PRICE AS p'
                             + N'   ON p.ITEM_BUSINESS_UNIT_LINK_ID = il.ITEM_BUSINESS_UNIT_LINK_ID'
                             + N' JOIN ' + @Prefijo + N'code AS pt'
                             + N'   ON pt.CODE_ID = p.PRICE_TYPE_CODE_ID AND pt.NAME = v.TipoPrecio'
                             + N' JOIN ' + @Prefijo + N'code AS it ON it.CODE_ID = i.ITEM_TYPE_CODE_ID'
                             + N' WHERE i.IS_ACTIVE = 1 AND p.IS_ACTIVE = 1'
                             + N'   AND it.NAME = ''PRODUCT_ITEM'';'
                             + N' DECLARE @n int = @@ROWCOUNT;'
                             + N' IF @n <> ' + CAST(@Esperadas AS nvarchar(10))
                             + N'   THROW 50010, N''El número de precios actualizados no coincide.'
                             + N' Se revirtió el lote.'', 1;'
                             + N' COMMIT; SELECT @n;';
                    BEGIN TRY
                        DELETE @Filas;
                        INSERT @Filas EXEC sp_executesql @Exec, N'@q nvarchar(max)', @q = @Sql;

                        UPDATE #Acciones SET Status = 'APLICADO'
                        WHERE Caja = @Caja AND Lote = @Lote;
                    END TRY
                    BEGIN CATCH
                        IF @@TRANCOUNT > 0 ROLLBACK;
                        SET @Errores += 1;
                        UPDATE #Acciones SET Status = 'ERROR', Mensaje = ERROR_MESSAGE()
                        WHERE Caja = @Caja AND Lote = @Lote;
                    END CATCH;

                    FETCH NEXT FROM cur_lotes INTO @Caja, @Servidor, @Prefijo, @Lote;
                END
                CLOSE cur_lotes;
                DEALLOCATE cur_lotes;
            END

            -------------------------------------------------------------------
            -- 8. Bitácora
            -------------------------------------------------------------------
            INSERT dbo.Job_Homologacion_Precios_Log
                   (EjecucionID, SKU, PriceType, Caja, Previous_Price, Winning_Price,
                    Winning_Source_Caja, Winning_Date, Accion, Status, Mensaje)
            SELECT @EjecucionID, SKU, TipoPrecio, Caja, PrecioActual, PrecioGanador,
                   CajaGanadora, FechaGanadora, Accion, Status, Mensaje
            FROM #Acciones;

            SELECT @Status = CASE WHEN @Errores > 0 THEN 'PARCIAL' ELSE 'OK' END,
                   @Mensaje = CASE
                       WHEN @SoloReporte = 1 THEN N'Modo reporte: no se modificó ningún precio.'
                       WHEN @Errores > 0     THEN N'Hubo errores al actualizar algunas cajas.'
                                                + N' Revisar la bitácora.'
                       ELSE N'Precios homologados.' END;

            UPDATE dbo.Job_Homologacion_Precios_Ejecucion
               SET SKUsComparados = (SELECT COUNT(*) FROM #Resumen),
                   SKUsDiferentes = (SELECT COUNT(*) FROM #Resumen WHERE Estatus = 'DIFERENTES'),
                   Cambios        = (SELECT COUNT(*) FROM #Acciones WHERE Accion = 'ACTUALIZAR'),
                   PorRevisar     = (SELECT COUNT(*) FROM #Acciones WHERE Accion <> 'ACTUALIZAR')
            WHERE EjecucionID = @EjecucionID;

            -------------------------------------------------------------------
            -- 9. Resultado: comparativa de los SKUs con diferencias
            -------------------------------------------------------------------
            DECLARE @ColPrecios nvarchar(max), @ColFechas nvarchar(max);
            SELECT @ColPrecios = STRING_AGG(CAST(
                       N'MAX(CASE WHEN d.Caja = ' + QUOTENAME(Caja, N'''') + N' THEN d.Precio END) AS '
                       + QUOTENAME(N'Precio_' + Caja) AS nvarchar(max)), N', ')
                       WITHIN GROUP (ORDER BY Caja),
                   @ColFechas = STRING_AGG(CAST(
                       N'MAX(CASE WHEN d.Caja = ' + QUOTENAME(Caja, N'''') + N' THEN d.FechaRef END) AS '
                       + QUOTENAME(N'Fecha_' + Caja) AS nvarchar(max)), N', ')
                       WITHIN GROUP (ORDER BY Caja)
            FROM #Cajas;

            SET @Sql = N'SET ANSI_WARNINGS OFF;
                SELECT d.SKU, d.TipoPrecio, ' + @ColPrecios + N',
                       r.Estatus, ' + @ColFechas + N',
                       r.PrecioGanador AS Precio_Ganador,
                       r.CajaGanadora  AS Caja_Ganadora,
                       CASE WHEN r.PrecioGanador IS NOT NULL
                            THEN r.FechaMax END AS Fecha_Ganadora,
                       (SELECT STRING_AGG(CASE a.Accion
                                  WHEN ''ACTUALIZAR'' THEN ''UPDATE '' + a.Caja + '' a ''
                                                       + CONVERT(varchar(30), a.PrecioGanador)
                                  WHEN ''SIN_SKU''    THEN ''No existe en '' + a.Caja
                                  WHEN ''DUPLICADO''  THEN ''Precio duplicado en '' + a.Caja
                                  WHEN ''EMPATE''     THEN ''Empate de fecha en '' + a.Caja
                               END
                               + CASE a.Status WHEN ''APLICADO'' THEN '' (aplicado)''
                                               WHEN ''ERROR''    THEN '' (ERROR)'' ELSE '''' END,
                               ''; '') WITHIN GROUP (ORDER BY a.Caja)
                        FROM #Acciones AS a
                        WHERE a.SKU = d.SKU AND a.TipoPrecio = d.TipoPrecio) AS Accion
                FROM #Detalle AS d
                JOIN #Resumen AS r ON r.SKU = d.SKU AND r.TipoPrecio = d.TipoPrecio
                WHERE r.Estatus = ''DIFERENTES''
                GROUP BY d.SKU, d.TipoPrecio, r.Estatus, r.PrecioGanador,
                         r.CajaGanadora, r.FechaMax
                ORDER BY d.SKU, d.TipoPrecio;';
            EXEC sp_executesql @Sql;
        END

        -----------------------------------------------------------------------
        -- Cierre de la ejecución
        -----------------------------------------------------------------------
        UPDATE dbo.Job_Homologacion_Precios_Ejecucion
           SET Fin = SYSDATETIME(), Status = @Status, Mensaje = @Mensaje
        WHERE EjecucionID = @EjecucionID;

        SELECT EjecucionID, Modo, Status, SKUsComparados, SKUsDiferentes,
               Cambios, PorRevisar, Mensaje
        FROM dbo.Job_Homologacion_Precios_Ejecucion
        WHERE EjecucionID = @EjecucionID;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @Mensaje = ERROR_MESSAGE();

        UPDATE dbo.Job_Homologacion_Precios_Ejecucion
           SET Fin = SYSDATETIME(), Status = 'ERROR', Mensaje = @Mensaje
        WHERE EjecucionID = @EjecucionID;

        IF APPLOCK_MODE(N'public', N'Job_Homologacion_Precios', N'Session') <> N'NoLock'
            EXEC sp_releaseapplock @Resource = N'Job_Homologacion_Precios',
                                   @LockOwner = N'Session';
        THROW;
    END CATCH

    EXEC sp_releaseapplock @Resource = N'Job_Homologacion_Precios',
                           @LockOwner = N'Session';

    -- Cancelado o con errores: código de salida distinto de cero para la tarea programada
    IF @Status IN ('CANCELADO', 'PARCIAL')
        RAISERROR(@Mensaje, 16, 1);
END
GO


/* =============================================================================
   4. EJECUCIÓN
   ============================================================================= */
-- Solo reporte (no modifica nada):
-- EXEC HomologacionPrecios.dbo.usp_HomologarPrecios @SoloReporte = 1;

-- Aplicar cambios:
-- EXEC HomologacionPrecios.dbo.usp_HomologarPrecios @SoloReporte = 0;

-- Consultar las últimas ejecuciones y su detalle:
-- SELECT TOP (20) * FROM HomologacionPrecios.dbo.Job_Homologacion_Precios_Ejecucion
-- ORDER BY EjecucionID DESC;
-- SELECT * FROM HomologacionPrecios.dbo.Job_Homologacion_Precios_Log
-- WHERE EjecucionID = <ID> ORDER BY SKU, Caja;


/* =============================================================================
   5. SERVIDORES VINCULADOS (producción, en la Caja 2)
   -----------------------------------------------------------------------------
   Repetir por cada caja remota. El login remoto necesita SELECT en item,
   ITEM_BUSINESS_UNIT_LINK, PRICE y code, y UPDATE en PRICE.
   ============================================================================= */
-- EXEC sp_addlinkedserver
--      @server     = N'LNK_CAJA1',
--      @srvproduct = N'',
--      @provider   = N'MSOLEDBSQL',
--      @datasrc    = N'<SERVIDOR_CAJA1>\SQLEXPRESS',
--      @provstr    = N'Encrypt=yes;TrustServerCertificate=yes';
-- EXEC sp_addlinkedsrvlogin
--      @rmtsrvname  = N'LNK_CAJA1',
--      @useself     = N'FALSE',
--      @locallogin  = NULL,
--      @rmtuser     = N'<USUARIO>',
--      @rmtpassword = N'<PASSWORD>';
-- EXEC sp_serveroption N'LNK_CAJA1', 'rpc out', 'true';
-- EXEC sp_serveroption N'LNK_CAJA1', 'remote proc transaction promotion', 'false';
-- EXEC sp_serveroption N'LNK_CAJA1', 'connect timeout', '10';
-- EXEC sp_serveroption N'LNK_CAJA1', 'query timeout', '300';


/* =============================================================================
   6. TAREA PROGRAMADA (producción, en la Caja 2)
   -----------------------------------------------------------------------------
   SQL Server Express no tiene SQL Server Agent; se usa el Programador de
   tareas de Windows. Ejemplo cada 30 minutos (ejecutar como administrador):

   schtasks /Create /TN "Homologacion de precios" /SC MINUTE /MO 30 ^
     /TR "sqlcmd -S localhost\SQLEXPRESS -E -b -Q \"EXEC HomologacionPrecios.dbo.usp_HomologarPrecios @SoloReporte = 0\"" ^
     /RU <CUENTA> /RP <PASSWORD>
   ============================================================================= */
