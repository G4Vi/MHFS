# -*- coding: utf-8 -*-
# KodiAddon (MHFS)
#
from t1mlib import t1mAddon
import json
import re
import xbmcplugin
import xbmcgui
import sys
import xbmc
import requests
import urllib.parse

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

class myAddon(t1mAddon):
  def __init__(self, aname):
      super().__init__(aname)
      mhfsurl = self.addon.getSetting('mhfsurl')
      if not mhfsurl.endswith('/'):
          mhfsurl = ''.join([mhfsurl, '/'])
      self.MHFSBASE = ''.join([mhfsurl, 'kodi/'])

  def getAddonMenu(self,url,ilist):
      eprint(''.join(['MHFSBASE ', self.MHFSBASE]))
      ilist = self.addMenuItem('TV', 'GS', ilist, "tv", videoInfo={'mediatype':'tvshow'})
      ilist = self.addMenuItem('Movies', 'GM', ilist, "movies", videoInfo={'mediatype':'movie'})
      return(ilist)

  def getAddonShows(self,url,ilist):
      fullurl = ''.join([self.MHFSBASE,url,'/?fmt=json'])
      eprint(fullurl)
      encoded = requests.get(fullurl, headers=self.defaultHeaders).text
      a = json.loads(encoded)
      sortedlist = sorted(a, key=lambda d: d['item']) 
      for item in sortedlist:
          name = item['item']
          if item['isdir']:
              infoList = {'mediatype':'tvshow',
                         'TVShowTitle': name,
                         'Title': name}
              if 'plot' in item:
                  infoList['Plot'] = item['plot']
              thumb = ''.join([self.MHFSBASE, 'metadata/tv/thumb/', urllib.parse.quote(name)])
              fanart = ''.join([self.MHFSBASE, 'metadata/tv/fanart/', urllib.parse.quote(name)])
              ilist = self.addMenuItem(name,'GE', ilist, name, thumb=thumb, fanart=fanart, videoInfo=infoList, isFolder=True)
          else:
              infoList = {'mediatype':'episode',
                          'Title': name,
                          'TVShowTitle': name}
              ilist = self.addMenuItem(name,'GV', ilist, name, videoInfo=infoList, isFolder=False)
      return(ilist)

  def buildMovieMeta(self, displayname, moviename, movie):
      infoList = {'mediatype':'movie', 'Title': displayname}
      if 'year' in movie:
          infoList['Year'] = movie['year']
      if 'plot' in movie:
          infoList['Plot'] = movie['plot']
      thumb = ''.join([self.MHFSBASE, 'metadata/movies/thumb/', urllib.parse.quote(moviename)])
      fanart = ''.join([self.MHFSBASE, 'metadata/movies/fanart/', urllib.parse.quote(moviename)])
      eprint(''.join(['thumb ', thumb, ' fanart ', fanart]))
      return infoList, thumb, fanart

  def addMoviePart(self, displayname, ilist, item, video):
      infoList, thumb, fanart = self.buildMovieMeta(displayname, item['id'], item['movie'])
      newurl = json.dumps({'item': item, 'video': video})
      return self.addMenuItem(displayname,'GV', ilist, newurl, thumb=thumb, fanart=fanart, videoInfo=infoList, isFolder=False)

  def addMovieEdition(self, displayname, ilist, moviename, movie, editionname):
      infoList, thumb, fanart = self.buildMovieMeta(displayname, moviename, movie)
      edition = movie['editions'][editionname]
      if edition:
          item = {'id': moviename, 'movie': movie, 'editionname': editionname}
          if len(edition) > 1:
              newurl = json.dumps(item)
              return self.addMenuItem(displayname,'GM', ilist, newurl, thumb=thumb, fanart=fanart, videoInfo=infoList)
          else:
              return self.addMoviePart(displayname, ilist, item, list(edition.keys())[0])
      else:
          newurl = ''.join(['movies/', urllib.parse.quote(moviename), '/', urllib.parse.quote(editionname)])
      return self.addMenuItem(displayname,'GV', ilist, newurl, thumb=thumb, fanart=fanart, videoInfo=infoList, isFolder=False)

  def getAddonMovies(self,url,ilist):
      if url.startswith('{'):
          eprint(url)
          item = json.loads(url)
          movie = item['movie']
          if 'editionname' in item:
              for video in sorted(movie['editions'][item['editionname']].keys()):
                  ilist = self.addMoviePart(video, ilist, item, video)
          else:
              moviename = item['id']
              editionnames = sorted(movie['editions'].keys())
              for editionname in editionnames:
                  ilist = self.addMovieEdition(editionname, ilist, moviename, movie, editionname)
      elif url == 'movies':
          fullurl = ''.join([self.MHFSBASE,url,'/?fmt=json'])
          eprint(fullurl)
          encoded = requests.get(fullurl, headers=self.defaultHeaders).text
          movies = json.loads(encoded)
          for moviename in sorted(movies.keys()):
              movie = movies[moviename]
              if 'name' in movie:
                  displayname = movie['name']
              else:
                  displayname = moviename
              if len(movie['editions']) == 1:
                  editionname = list(movie['editions'].keys())[0]
                  ilist = self.addMovieEdition(displayname, ilist, moviename, movie, editionname)
              else:
                  infoList, thumb, fanart = self.buildMovieMeta(displayname, moviename, movie)
                  newurl = json.dumps({'id': moviename, 'movie': movie})
                  ilist = self.addMenuItem(displayname,'GM', ilist, newurl, thumb=thumb, fanart=fanart, videoInfo=infoList)
      return(ilist)

  def getAddonEpisodes(self,url,ilist):
      fullurl = ''.join([self.MHFSBASE,'tv/', url,'/?fmt=json'])
      eprint(fullurl)
      encoded = requests.get(fullurl, headers=self.defaultHeaders).text
      a = json.loads(encoded)
      sortedlist = sorted(a, key=lambda d: d['item']) 
      for item in sortedlist:
          name = item['item']
          newurl = ''.join(['tv/', urllib.parse.quote(url), '/', urllib.parse.quote(name)])
          eprint(newurl)
          if item['isdir']:
              infoList = {'mediatype':'tvshow',
                         'TVShowTitle': xbmc.getInfoLabel('ListItem.TVShowTitle'),
                         'Title': name}
              ilist = self.addMenuItem(name,'GE', ilist, newurl, videoInfo=infoList, isFolder=True)
          else:
              infoList = {'mediatype':'episode',
                          'Title': name,
                          'TVShowTitle': xbmc.getInfoLabel('ListItem.TVShowTitle')}
              ilist = self.addMenuItem(name,'GV', ilist, newurl, videoInfo=infoList, isFolder=False)
      return(ilist)

  def getAddonVideo(self,url):
      subtitle_files = []
      if not url.startswith('{'):
          newurl = ''.join([self.MHFSBASE, url])
      else:
          meta = json.loads(url)
          newurl = ''.join([self.MHFSBASE, 'movies/', urllib.parse.quote(meta['item']['id']), '/', urllib.parse.quote(meta['item']['editionname']), '/'])
          editionname = meta['item']['editionname']
          video = meta['video']
          if 'subs' in meta['item']['movie']['editions'][editionname][video]:
              for sub in meta['item']['movie']['editions'][editionname][video]['subs']:
                  subtitle_files.append(''.join([newurl, urllib.parse.quote(sub)]))
          eprint('logging')
          eprint(newurl)
          newurl = newurl + urllib.parse.quote(meta['video'])
      eprint(newurl)
      liz = xbmcgui.ListItem(path = newurl, offscreen=True)
      if len(subtitle_files):
          liz.setSubtitles(subtitle_files)
      xbmcplugin.setResolvedUrl(int(sys.argv[1]), True, liz)
