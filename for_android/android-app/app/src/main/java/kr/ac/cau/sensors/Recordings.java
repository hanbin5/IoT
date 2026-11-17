package kr.ac.cau.sensors;

import android.content.*;
import android.database.Cursor;
import android.database.sqlite.*;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.zip.*;

final class Recordings extends SQLiteOpenHelper {
    private static Recordings instance;
    static synchronized Recordings open(Context c) {
        if (instance == null) instance = new Recordings(c.getApplicationContext());
        return instance;
    }
    private Recordings(Context c) { super(c,"recordings.db",null,1); setWriteAheadLoggingEnabled(true); }
    @Override public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE sessions(s TEXT PRIMARY KEY, device TEXT, meta TEXT, url TEXT)");
        db.execSQL("CREATE TABLE batches(id INTEGER PRIMARY KEY, s TEXT, payload TEXT, n INTEGER, sent INTEGER DEFAULT 0)");
        db.execSQL("CREATE INDEX pending ON batches(sent,id)");
        db.execSQL("CREATE INDEX session_order ON batches(s,id)");
    }
    @Override public void onUpgrade(SQLiteDatabase db,int oldVersion,int newVersion) {}
    void begin(String session,String device,JSONObject meta,String url) {
        getWritableDatabase().execSQL("INSERT INTO sessions VALUES(?,?,?,?)",new Object[]{session,device,meta.toString(),url});
    }
    void append(String s,JSONArray data) {
        getWritableDatabase().execSQL("INSERT INTO batches(s,payload,n) VALUES(?,?,?)",new Object[]{s,data.toString(),data.length()});
    }
    void export(OutputStream output) throws Exception {
        String[] motion = "acc_x acc_y acc_z grav_x grav_y grav_z gyro_x gyro_y gyro_z mag_x mag_y mag_z mag_accuracy quat_w quat_x quat_y quat_z".split(" ");
        SQLiteDatabase db = getReadableDatabase();
        try (ZipOutputStream zip = new ZipOutputStream(new BufferedOutputStream(output));
             Cursor sessions = db.rawQuery("SELECT s,meta,device FROM sessions ORDER BY rowid",null)) {
            while (sessions.moveToNext()) {
                String s = sessions.getString(0);
                zip.putNextEntry(new ZipEntry(s+"/meta.json"));
                write(zip,new JSONObject(sessions.getString(1)).put("sessionId",s).put("deviceId",sessions.getString(2)).toString());
                zip.closeEntry();
                for (String name : new String[]{"motion","barometer"}) {
                    String[] keys = name.equals("motion") ? motion : new String[]{"pressure_hpa","rel_alt_m"};
                    boolean opened = false;
                    try (Cursor rows = db.rawQuery("SELECT payload FROM batches WHERE s=? ORDER BY id",new String[]{s})) {
                        while (rows.moveToNext()) {
                            JSONArray batch = new JSONArray(rows.getString(0));
                            StringBuilder lines = new StringBuilder();
                            for (int i=0;i<batch.length();i++) {
                                JSONObject item = batch.getJSONObject(i);
                                if (!name.equals(item.getString("name"))) continue;
                                if (!opened) {
                                    zip.putNextEntry(new ZipEntry(s+"/"+name+".csv"));
                                    lines.append("time,").append(String.join(",",keys)).append('\n');
                                    opened = true;
                                }
                                lines.append(item.getLong("time"));
                                JSONObject v = item.getJSONObject("values");
                                for (String key : keys) lines.append(',').append(v.isNull(key)?"":v.getString(key));
                                lines.append('\n');
                            }
                            write(zip,lines.toString());
                        }
                    }
                    if (opened) zip.closeEntry();
                }
            }
        }
    }
    private static void write(OutputStream out,String s) throws IOException { out.write(s.getBytes(StandardCharsets.UTF_8)); }
}
