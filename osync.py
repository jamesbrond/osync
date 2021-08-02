#!/usr/bin/env python3

# Requires
# svn: pip install svn

import argparse
import configparser
from distutils.spawn import find_executable
import os
import errno
import re
import subprocess
import sys
import time

import svn.local
import logging
from logging import FileHandler, StreamHandler

version = "2.0"
lastmod = "2018-03-19"

def parse_cmd_line():
  parser = argparse.ArgumentParser(prog='OSYNC',
                                   usage='%(prog)s [options]',
                                   description='Oracle Synchronization Tool',
                                   epilog='program realized to remember the victims of perl - copyleft James Brond ~@:-]')

  # oracle options
  parser.add_argument('-c', '--connection-string', required=True, dest='conn', help='oracle\'s connection string username/password@host[:port][/service_name]')
  # path options
  parser.add_argument('-s', '--source', required=True, dest='source', help='set local repository where PL/SQL source code is')
  parser.add_argument('-e', '--excludes', dest='excludes', help='comma separated list of files to escape')
  # tools options
  parser.add_argument('-sqlplus', dest='sqlplus', help='path to SQLPlus command')
  # logging options
  parser.add_argument('-q', '--quiet', required=False, dest='debuglevel', action='store_const', const=logging.NOTSET, default=logging.ERROR, help='suppress debug level messages')
  parser.add_argument('-v', '--verbose', required=False, dest='debuglevel', action='store_const', const=logging.INFO, default=logging.ERROR, help='increase verbosity level (INFO)')
  parser.add_argument('-vv', '--very-verbose', required=False, dest='debuglevel', action='store_const', const=logging.DEBUG, default=logging.ERROR, help='increase verbosity to higher level (DEBUG)')
  # revision tool
  parser.add_argument('--use-git', required=False, dest='usegit', action='store_true', help='use git as revision control')
  parser.add_argument('--use-svn', required=False, dest='usesvn', action='store_true', default=True, help='use subversion as revision control (default option)')
  # version
  parser.add_argument('--version', action='version', version='%(prog)s ' + version + ' ' + lastmod)
  return parser.parse_args()


def log():
  global g_args
  L = logging.getLogger('osync')
  L.setLevel(g_args.debuglevel)
  if not L.handlers:
    formatter = logging.Formatter('%(asctime)s [%(levelname)-5s] %(message)s (%(lineno)d)')
    file_name = os.path.join(g_args.source, '.osync', 'osync.log')
    if not os.path.exists(os.path.dirname(file_name)):
      try:
        os.makedirs(os.path.dirname(file_name))
      except OSError as exc:
        if exc.errno != errno.EEXIST:
          raise
    # log to file
    handler = FileHandler(file_name, mode='w', encoding='utf-8')
    handler.setFormatter(formatter)
    handler.setLevel(g_args.debuglevel)
    L.addHandler(handler)

    # log to system output
    handler = StreamHandler(stream=sys.stdout)
    handler.setFormatter(formatter)
    handler.setLevel(g_args.debuglevel)
    L.addHandler(handler)
  return L


def read_config(source):
  global L
  # parse config file
  # OSYNC use configuration file stored in local repository (.osync)
  cfg_path = os.path.join(source, '.osync', 'config')
  cfg = configparser.ConfigParser()
  if not os.path.exists(cfg_path):
    # if configuration file doesn't exist, create it
    L.debug('creating configuration file at %s', cfg_path)
    if not os.path.exists(os.path.join(g_args.source, '.osync')):
      os.makedirs(os.path.join(g_args.source, '.osync'))
    open(cfg_path, 'w').close()
  else:
    L.debug('open configuration file at %s', cfg_path)
    with open(cfg_path) as c:
      cfg.read_file(c)

  return cfg


def write_config(source):
  global g_cfg
  L.info('save config')
  cfg_path = os.path.join(source, '.osync', 'config')
  L.debug('conig path: %s', cfg_path)
  with open(cfg_path, 'w') as c:
    g_cfg.write(c)


def write_patch(sqlfilename, patchfilename, spoolfilename):
  global L
  if os.path.exists(sqlfilename) and os.path.isfile(sqlfilename):
    with open(sqlfilename, 'rb') as f:
      with open(patchfilename, 'wb') as p:
        p.write(b'SET ECHO OFF\n')
        p.write(b'SET VERIFY OFF\n')
        p.write(b'SET HEADING OFF\n')
        p.write(b'SET TERMOUT OFF\n')
        p.write(b'SET TRIMOUT ON\n')
        p.write(b'SET TRIMSPOOL ON\n')
        p.write(b'SET WRAP OFF\n')
        p.write(b'SET LINESIZE 32000\n')
        p.write(b'SET LONG 32000\n')
        p.write(b'SET LONGCHUNKSIZE 32000\n')
        p.write(b'SET SERVEROUT ON\n')
        p.write(b'SET DEFINE OFF\n')
        p.write(b'SET PAGESIZE 0\n')
        p.write(bytes('SPOOL ' + spoolfilename + ' APPEND\n\n', 'utf-8'))
        p.write(bytes('PROMPT +' + '-' * 80 + '+\n', 'utf-8'))
        p.write(bytes('PROMPT +- START FILE: ' + sqlfilename + '\n', 'utf-8'))
        for line in f:
          p.write(line)
        p.write(b'\n\n')
        p.write(bytes('PROMPT +- END FILE: ' + sqlfilename + '\n', 'utf-8'))
        p.write(bytes('PROMPT +' + '-' * 80 + '+\n', 'utf-8'))
        p.write(b'SPOOL OFF\n')
        p.write(b'QUIT\n')
        return True
  return False


def exec_sqlplus(patchfilename):
  global g_args
  L.debug('%s -s %s @%s', g_args.sqlplus, g_args.conn, patchfilename)
  subprocess.call([g_args.sqlplus, '-s', g_args.conn, '@' + patchfilename], cwd=g_args.source)


def run_changes(changes):
  global g_args

  patchfile = os.path.join(g_args.source, '.osync', 'patch.sql')
  L.debug('temporary patch file: %s', patchfile)

  spoolfile = os.path.join(g_args.source, '.osync', 'patch_' + time.strftime("%Y%m%d-%H%M%S") + '.log')
  L.debug('oracle spool file: %s', spoolfile)
  for file in changes:
    L.info('execute %s script', file)
    full_path = os.path.join(g_args.source, *file.split('/'))
    if write_patch(full_path, patchfile, spoolfile):
      exec_sqlplus(patchfile)
      os.remove(patchfile)

  # compile invalid objects
  invalidObj = """declare
                    n_invalid_objs number;
                  begin
                    select count(*) into n_invalid_objs from user_objects where object_type in ('VIEW', 'PROCEDURE', 'FUNCTION', 'TRIGGER', 'PACKAGE', 'PACKAGE BODY') and status != 'VALID';

                    if n_invalid_objs > 0 then
                      dbms_output.put_line('found ' || n_invalid_objs || ' invalid objects');
                      dbms_output.put_line('try to re-compile');
                      for obj in (select object_name,
                                         object_type,
                                         decode(object_type, 'PACKAGE', 1, 'PACKAGE BODY', 2, 0) as recompile_order
                                  from user_objects
                                 where object_type in ('VIEW', 'PROCEDURE', 'FUNCTION', 'TRIGGER', 'PACKAGE', 'PACKAGE BODY')
                                   and status != 'VALID'
                                 order by 3) loop
                        begin
                          dbms_output.put_line('> ' || obj.object_name);
                          if obj.object_type = 'PACKAGE BODY' then
                            execute immediate 'ALTER PACKAGE ' || obj.object_name || ' COMPILE BODY';
                          else
                            execute immediate 'ALTER ' || obj.object_type || ' ' || obj.object_name || ' COMPILE';
                        end if;
                        exception
                          when others then
                            dbms_output.put_line('Failed: ' || obj.object_type || ' : ' || obj.object_name);
                        end;
                      end loop;
                      dbms_output.put_line('done');
                    else
                      dbms_output.put_line('no invalid objects');
                    end if;
                  end;
                  /"""
  L.debug('Recompile invalid objects')
  with open(patchfile, 'w', encoding='utf8') as p:
    p.write('SET ECHO OFF\n')
    p.write('SET VERIFY OFF\n')
    p.write('SET HEADING OFF\n')
    p.write('SET TERMOUT OFF\n')
    p.write('SET TRIMOUT ON\n')
    p.write('SET TRIMSPOOL ON\n')
    p.write('SET WRAP OFF\n')
    p.write('SET LINESIZE 32000\n')
    p.write('SET LONG 32000\n')
    p.write('SET LONGCHUNKSIZE 32000\n')
    p.write('SET SERVEROUT ON\n')
    p.write('SET DEFINE OFF\n')
    p.write('SET PAGESIZE 0\n')
    p.write('SPOOL ' + spoolfile + ' APPEND\n\n')
    p.write(invalidObj)
    p.write('\n\n')
    p.write('PROMPT +- END FILE: ' + file + '\n')
    p.write('PROMPT +' + '-' * 80 + '+\n')
    p.write('SPOOL OFF\n')
    p.write('QUIT\n')
  exec_sqlplus(patchfile)
  os.remove(patchfile)


def svn_changes():
  global g_args
  global g_cfg

  try:
    last_rev = int(g_cfg['svn'].get('rev', 0))
  except KeyError:
    g_cfg['svn'] = {}
    last_rev = 0

  regexp = r'/([^/]*)$'
  p = re.compile(regexp)
  match = p.findall(g_args.source)[0] + '/'
  p = re.compile(match + '(.*)$')

  L.debug('local SVN repository: %s', g_args.source)
  svn_local = svn.local.LocalClient(g_args.source)
  L.info('check for changes in PLSQL scripts')
  head_rev = svn_local.info()['commit_revision']

  L.info('last revision checked: %s - HEAD revision: %s', last_rev, head_rev)

  if last_rev >= head_rev:
    L.info('nothing to do')
    sys.exit(0)

  L.info('check for changes in SQL scripts')
  changes = []
  for entry in svn_local.log_default(revision_from=last_rev, revision_to=head_rev, changelist=True):
    for change in entry.changelist:
      if match in change[1]:
        file = p.findall(change[1])[0]
        if not file in changes:
          if not file in g_args.excludes:
            L.debug('found %s', file)
            changes.append(file)
          else:
            L.debug('skip %s', file)

  g_cfg['svn']['rev'] = str(head_rev)
  return changes


def git_changes():
  global g_args
  global g_cfg
  changes = []

  try:
    last_branch = g_cfg['git'].get('branch', 0)
  except KeyError:
    g_cfg['git'] = {}
    last_branch = 'master'

  cmd = 'git rev-parse --abbrev-ref HEAD'
  L.debug('get current branch %s' % cmd)
  process = subprocess.Popen(cmd, cwd=g_args.source, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
  while True:
    out = process.stdout.readline()
    if out == b'' and process.poll() != None:
      break
    if out != b'':
      head_branch = out.decode("utf-8").rstrip()
  g_cfg['git']['branch'] = head_branch

  L.info('changes from %s to %s branch', last_branch, head_branch)
  L.debug('local GIT repository: %s', g_args.source)

  if last_branch == head_branch:
    L.info('nothing to do')
    sys.exit(0)

  regexp = r'/([^/]*)$'
  p = re.compile(regexp)
  match = p.findall(g_args.source)[0] + '/'
  p = re.compile(match + '(.*)$')

  cmd = 'git diff --name-status ' + last_branch  + ' -- .'
  L.debug('get list of changes %s' % cmd)
  process = subprocess.Popen(cmd, cwd=g_args.source, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
  while True:
    out = process.stdout.readline()
    if out == b'' and process.poll() != None:
      break
    out = out.decode("utf-8")
    if out != '' and not out.startswith('D') and match in out:
      file = p.findall(out)[0]
      if not file in changes:
        if not file in g_args.excludes:
          L.debug('found %s', file)
          changes.append(file)
        else:
          L.debug('skip %s', file)
  return changes

#===============================================================================
# MAIN
#===============================================================================
g_args = parse_cmd_line()
L = log()

try:
  # check source
  if not os.path.exists(g_args.source) or not os.path.isdir(g_args.source):
    raise FileNotFoundError('local repository is not a valid folder')

  # check sqlplus
  if not g_args.sqlplus:
    # if not specified sqlplus executable must be in PATH
    g_args.sqlplus = find_executable('sqlplus.exe')
    if g_args.sqlplus == None:
      raise SystemError('missing sqlplus executable')

  # excludes to array
  if g_args.excludes:
    g_args.excludes = [x.strip() for x in g_args.excludes.split(',')]

  g_cfg = read_config(g_args.source)

  if g_args.usegit:
    changes = git_changes()
  elif g_args.usesvn:
    changes = svn_changes()
  else:
    changes = []

  L.info('found %d SQL files to update', len(changes))
  if len(changes) == 0:
    L.info('nothing to do')
    sys.exit(0)

  run_changes(changes)
  
  write_config(g_args.source)

  L.debug('done')
  sys.exit(0)
except Exception as e:
  L.exception(e)
  sys.exit(192)

# ~@:-]
